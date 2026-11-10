/*
 * Early board init for DIBS (nRF52832-CIAA).
 */
#include <zephyr/init.h>
#include <hal/nrf_gpio.h>
#include <nrfx.h>

/* Q1 gate for the battery-powered LED D1. The gate has no pull-down, so
 * drive it low before anything else runs to keep the LED from glowing. */
#define LED_GATE_PIN 18

/* PDM clock to the ICS-41350 (MK2). The microphone only sleeps (12 uA)
 * when its clock is held low; floating it may keep it awake. The PDM driver
 * takes the pin over while recording. */
#define MIC_CLK_PIN 16

#if defined(CONFIG_DIBS_OPEN_DEBUG_PORT)
static void nvmc_wait(void)
{
	while (NRF_NVMC->READY == NVMC_READY_READY_Busy) {
	}
}

static void open_debug_port(void)
{
	if (NRF_UICR->APPROTECT == UICR_APPROTECT_PALL_HwDisabled) {
		return;
	}

	NRF_NVMC->CONFIG = NVMC_CONFIG_WEN_Wen;
	nvmc_wait();
	NRF_UICR->APPROTECT = UICR_APPROTECT_PALL_HwDisabled;
	nvmc_wait();
	NRF_NVMC->CONFIG = NVMC_CONFIG_WEN_Ren;
	nvmc_wait();

	/* SystemInit() applies UICR.APPROTECT on the next boot. */
	NVIC_SystemReset();
}
#endif

static int dibs_board_init(void)
{
	nrf_gpio_pin_clear(LED_GATE_PIN);
	nrf_gpio_cfg_output(LED_GATE_PIN);
	nrf_gpio_pin_clear(MIC_CLK_PIN);
	nrf_gpio_cfg_output(MIC_CLK_PIN);

#if defined(CONFIG_DIBS_OPEN_DEBUG_PORT)
	open_debug_port();
#endif
	return 0;
}

SYS_INIT(dibs_board_init, PRE_KERNEL_1, 0);
