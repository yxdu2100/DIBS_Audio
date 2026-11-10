/*
 * Sleep-floor test: after reset every chip on the board is in its power-on
 * state (IMU powered down, microphone without clock, fuel gauge and charger
 * idle) and the nRF52832 sleeps in System ON with only the RTC running.
 * Power-cycle the board before measuring: a WDT left running by the main
 * firmware would otherwise reset this one.
 */
#include <zephyr/kernel.h>

int main(void)
{
	return 0;
}
