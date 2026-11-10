#include "ble.h"

#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

#include "power.h"
#include "protocol.h"
#include "session.h"

LOG_MODULE_REGISTER(ble, LOG_LEVEL_INF);

static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(DIBS_UUID_SERVICE);
static const struct bt_uuid_128 control_uuid = BT_UUID_INIT_128(DIBS_UUID_CONTROL);
static const struct bt_uuid_128 audio_uuid = BT_UUID_INIT_128(DIBS_UUID_AUDIO);
static const struct bt_uuid_128 status_uuid = BT_UUID_INIT_128(DIBS_UUID_STATUS);
static const struct bt_uuid_128 battery_uuid = BT_UUID_INIT_128(DIBS_UUID_BATTERY);
static const struct bt_uuid_128 imu_uuid = BT_UUID_INIT_128(DIBS_UUID_IMU);

static struct bt_conn *current_conn;
static bool audio_subscribed;
static bool status_subscribed;
static bool battery_subscribed;
static bool imu_subscribed;
static struct dibs_status status = { .version = DIBS_PROTOCOL_VERSION };
static struct dibs_battery battery = { .version = 1 };

static ssize_t control_write(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			     const void *buf, uint16_t len, uint16_t offset, uint8_t flags)
{
	if (offset != 0 || len != 1) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	switch (((const uint8_t *)buf)[0]) {
	case DIBS_CMD_START:
		session_start();
		break;
	case DIBS_CMD_STOP:
		session_stop(DIBS_END_STOP);
		break;
	default:
		return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
	}
	return len;
}

static ssize_t status_read(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			   void *buf, uint16_t len, uint16_t offset)
{
	return bt_gatt_attr_read(conn, attr, buf, len, offset, &status, sizeof(status));
}

static ssize_t battery_read(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			    void *buf, uint16_t len, uint16_t offset)
{
	return bt_gatt_attr_read(conn, attr, buf, len, offset, &battery, sizeof(battery));
}

static void audio_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	audio_subscribed = value == BT_GATT_CCC_NOTIFY;
}

static void status_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	status_subscribed = value == BT_GATT_CCC_NOTIFY;
}

static void battery_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	battery_subscribed = value == BT_GATT_CCC_NOTIFY;
}

static void imu_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	imu_subscribed = value == BT_GATT_CCC_NOTIFY;
}

BT_GATT_SERVICE_DEFINE(dibs_svc,
	BT_GATT_PRIMARY_SERVICE(&svc_uuid),
	BT_GATT_CHARACTERISTIC(&control_uuid.uuid,
			       BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE, NULL, control_write, NULL),
	BT_GATT_CHARACTERISTIC(&audio_uuid.uuid, BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, NULL, NULL, NULL),
	BT_GATT_CCC(audio_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&status_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ, status_read, NULL, NULL),
	BT_GATT_CCC(status_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&battery_uuid.uuid,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ, battery_read, NULL, NULL),
	BT_GATT_CCC(battery_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(&imu_uuid.uuid, BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, NULL, NULL, NULL),
	BT_GATT_CCC(imu_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* Attribute indices in dibs_svc used for notifications. */
#define ATTR_AUDIO   4
#define ATTR_STATUS  7
#define ATTR_BATTERY 10
#define ATTR_IMU     13

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, DIBS_UUID_SERVICE),
};

/* "DIBS_Audio-XXXX", XXXX = low 16 bits of the FICR device ID, so several
 * boards can be told apart in the phone's device list (15 characters: fits
 * the scan response). */
static char device_name[sizeof("DIBS_Audio-XXXX")];

static struct bt_data sd[] = {
	BT_DATA(BT_DATA_NAME_COMPLETE, device_name, 0),
};

/* 1.00-1.08 s: slow enough to cost little, and iOS still finds the board
 * within a few seconds. */
static const struct bt_le_adv_param *adv_param =
	BT_LE_ADV_PARAM(BT_LE_ADV_OPT_CONN, 0x0640, 0x06C0, NULL);

/* Units: interval 1.25 ms, timeout 10 ms. Idle: 30-45 ms with latency 20,
 * so with nothing to send the board wakes about once a second. Recording:
 * 15-30 ms without latency for the audio + IMU stream. Both fit Apple's
 * rules (multiples of 15 ms, latency <= 30, timeout 6 s). */
static const struct bt_le_conn_param idle_link = BT_LE_CONN_PARAM_INIT(24, 36, 20, 600);
static const struct bt_le_conn_param fast_link = BT_LE_CONN_PARAM_INIT(12, 24, 0, 600);

static atomic_t adv_allowed = ATOMIC_INIT(1);
static atomic_t fast_link_wanted;

static void advertise(void)
{
	if (!atomic_get(&adv_allowed) || current_conn) {
		return;
	}

	int err = bt_le_adv_start(adv_param, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));

	if (err == -EALREADY) {
		return;
	}
	if (err) {
		/* Usually -ENOMEM until the last connection is recycled, which
		 * calls advertise() again. */
		LOG_WRN("advertising failed: %d", err);
	} else {
		LOG_INF("advertising as \"%s\"", device_name);
	}
}

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		LOG_WRN("connection failed: 0x%02x", err);
		return;
	}
	LOG_INF("connected");
	current_conn = bt_conn_ref(conn);
	power_set_connected(true);

	bt_conn_le_param_update(conn, atomic_get(&fast_link_wanted) ? &fast_link : &idle_link);
	/* 2M PHY and 251-byte data length are negotiated by the host
	 * automatically (BT_AUTO_PHY_UPDATE, BT_AUTO_DATA_LEN_UPDATE). Don't
	 * request them here: this callback runs on the thread that has to
	 * process their HCI responses. */
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	LOG_INF("disconnected: 0x%02x", reason);
	session_stop(DIBS_END_DISCONNECT);
	audio_subscribed = false;
	imu_subscribed = false;
	status_subscribed = false;
	battery_subscribed = false;
	if (current_conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
	}
	power_set_connected(false);
}

static void recycled(void)
{
	advertise();
}

static void le_param_updated(struct bt_conn *conn, uint16_t interval,
			     uint16_t latency, uint16_t timeout)
{
	LOG_INF("conn interval %u.%02u ms", interval * 125 / 100, interval * 125 % 100);
}

static void le_phy_updated(struct bt_conn *conn, struct bt_conn_le_phy_info *info)
{
	LOG_INF("PHY tx %u rx %u", info->tx_phy, info->rx_phy);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
	.recycled = recycled,
	.le_param_updated = le_param_updated,
	.le_phy_updated = le_phy_updated,
};

static void mtu_updated(struct bt_conn *conn, uint16_t tx, uint16_t rx)
{
	LOG_INF("ATT MTU %u", bt_gatt_get_mtu(conn));
}

static struct bt_gatt_cb gatt_callbacks = {
	.att_mtu_updated = mtu_updated,
};

int ble_init(void)
{
	snprintk(device_name, sizeof(device_name), "DIBS_Audio-%04X",
		 (uint16_t)NRF_FICR->DEVICEID[0]);
	sd[0].data_len = strlen(device_name);

	int err = bt_enable(NULL);

	if (err) {
		LOG_ERR("bt_enable: %d", err);
		return err;
	}
	err = bt_set_name(device_name);
	if (err) {
		LOG_WRN("bt_set_name: %d", err);
	}
	bt_gatt_cb_register(&gatt_callbacks);
	advertise();
	return 0;
}

void ble_set_advertising(bool allowed)
{
	atomic_set(&adv_allowed, allowed);
	if (allowed) {
		advertise();
	} else if (!current_conn) {
		bt_le_adv_stop();
		LOG_INF("advertising stopped (parked)");
	}
}

void ble_set_link_fast(bool fast)
{
	atomic_set(&fast_link_wanted, fast);
	if (current_conn) {
		bt_conn_le_param_update(current_conn, fast ? &fast_link : &idle_link);
	}
}

size_t ble_audio_max_len(void)
{
	if (!current_conn || !audio_subscribed) {
		return 0;
	}
	return bt_gatt_get_mtu(current_conn) - 3;
}

int ble_send_audio(const uint8_t *data, size_t len)
{
	if (!current_conn || !audio_subscribed) {
		return -ENOTCONN;
	}
	return bt_gatt_notify(current_conn, &dibs_svc.attrs[ATTR_AUDIO], data, len);
}

int ble_send_imu(const uint8_t *data, size_t len)
{
	if (!current_conn || !imu_subscribed) {
		return -ENOTCONN;
	}
	if (len > bt_gatt_get_mtu(current_conn) - 3) {
		return -EMSGSIZE;
	}
	return bt_gatt_notify(current_conn, &dibs_svc.attrs[ATTR_IMU], data, len);
}

void ble_set_status(const struct dibs_status *s)
{
	/* The struct is little-endian on the wire, like this CPU. */
	status = *s;
	status.version = DIBS_PROTOCOL_VERSION;

	if (current_conn && status_subscribed) {
		bt_gatt_notify(current_conn, &dibs_svc.attrs[ATTR_STATUS], &status,
			       sizeof(status));
	}
}

void ble_set_battery(const struct dibs_battery *b)
{
	battery = *b;
	battery.voltage_mv = sys_cpu_to_le16(b->voltage_mv);

	if (current_conn && battery_subscribed) {
		bt_gatt_notify(current_conn, &dibs_svc.attrs[ATTR_BATTERY], &battery,
			       sizeof(battery));
	}
}
