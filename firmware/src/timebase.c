#include "timebase.h"

#include <hal/nrf_pdm.h>
#include <hal/nrf_timer.h>
#include <nrfx_ppi.h>
#include <zephyr/drivers/clock_control/nrf_clock_control.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(timebase, LOG_LEVEL_INF);

/* MPSL owns TIMER0; TIMER3 has six capture registers and no other user. */
#define TB             NRF_TIMER3
#define CC_SOFTWARE    0
#define CC_PDM_STARTED 1
#define CC_PDM_END     2
#define PRESCALER_1MHZ 4 /* 16 MHz / 2^4 */

static struct onoff_manager *hf_mgr;
static struct onoff_client hf_cli;
static bool running;

static nrf_ppi_channel_t pdm_ch;
static nrf_ppi_channel_group_t pdm_grp;
static nrf_ppi_channel_t end_ch;

int timebase_init(void)
{
	hf_mgr = z_nrf_clock_control_get_onoff(CLOCK_CONTROL_NRF_SUBSYS_HF);

	if (nrfx_ppi_channel_alloc(&pdm_ch) != NRFX_SUCCESS ||
	    nrfx_ppi_channel_alloc(&end_ch) != NRFX_SUCCESS ||
	    nrfx_ppi_group_alloc(&pdm_grp) != NRFX_SUCCESS) {
		LOG_ERR("no free PPI channel/group");
		return -EBUSY;
	}

	/* PDM STARTED -> capture, and the same event disables the channel's
	 * group, so only the first buffer start of a session is captured. */
	nrfx_ppi_channel_assign(pdm_ch,
				nrf_pdm_event_address_get(NRF_PDM, NRF_PDM_EVENT_STARTED),
				nrf_timer_task_address_get(TB,
					nrf_timer_capture_task_get(CC_PDM_STARTED)));
	nrfx_ppi_channel_fork_assign(pdm_ch, nrfx_ppi_task_group_disable_address_get(pdm_grp));
	nrfx_ppi_channel_include_in_group(pdm_ch, pdm_grp);

	/* PDM END (a buffer is full) -> capture, on every buffer. */
	nrfx_ppi_channel_assign(end_ch,
				nrf_pdm_event_address_get(NRF_PDM, NRF_PDM_EVENT_END),
				nrf_timer_task_address_get(TB,
					nrf_timer_capture_task_get(CC_PDM_END)));

	nrf_timer_mode_set(TB, NRF_TIMER_MODE_TIMER);
	nrf_timer_bit_width_set(TB, NRF_TIMER_BIT_WIDTH_32);
	nrf_timer_prescaler_set(TB, PRESCALER_1MHZ);
	return 0;
}

int timebase_start(void)
{
	int res, err;

	/* Run the timer from the crystal, not the RC oscillator. */
	sys_notify_init_spinwait(&hf_cli.notify);
	err = onoff_request(hf_mgr, &hf_cli);
	if (err < 0) {
		return err;
	}
	while (sys_notify_fetch_result(&hf_cli.notify, &res) == -EAGAIN) {
		k_msleep(1);
	}

	nrf_timer_task_trigger(TB, NRF_TIMER_TASK_CLEAR);
	nrf_timer_cc_set(TB, CC_PDM_STARTED, 0);
	nrf_timer_cc_set(TB, CC_PDM_END, 0);
	nrf_timer_task_trigger(TB, NRF_TIMER_TASK_START);
	nrfx_ppi_channel_enable(end_ch);
	running = true;
	return 0;
}

void timebase_stop(void)
{
	if (!running) {
		return;
	}
	nrfx_ppi_group_disable(pdm_grp);
	nrfx_ppi_channel_disable(end_ch);
	nrf_timer_task_trigger(TB, NRF_TIMER_TASK_STOP);
	nrf_timer_task_trigger(TB, NRF_TIMER_TASK_SHUTDOWN);
	onoff_release(hf_mgr);
	running = false;
}

uint32_t timebase_now_us(void)
{
	unsigned int key = irq_lock();
	uint32_t t;

	nrf_timer_task_trigger(TB, nrf_timer_capture_task_get(CC_SOFTWARE));
	t = nrf_timer_cc_get(TB, CC_SOFTWARE);
	irq_unlock(key);
	return t;
}

void timebase_arm_pdm_capture(void)
{
	nrf_timer_cc_set(TB, CC_PDM_STARTED, 0);
	nrfx_ppi_group_enable(pdm_grp);
}

bool timebase_pdm_started_us(uint32_t *t_us)
{
	*t_us = nrf_timer_cc_get(TB, CC_PDM_STARTED);
	return *t_us != 0;
}

uint32_t timebase_pdm_end_us(void)
{
	return nrf_timer_cc_get(TB, CC_PDM_END);
}
