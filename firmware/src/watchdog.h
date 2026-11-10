#ifndef DIBS_WATCHDOG_H_
#define DIBS_WATCHDOG_H_

/*
 * Task watchdog on top of the hardware WDT: the system workqueue is always
 * watched; the session and IMU threads add a channel while they run. A
 * channel that is not fed in time resets the board (RESETREAS shows DOG).
 */
int watchdog_init(void);

#endif /* DIBS_WATCHDOG_H_ */
