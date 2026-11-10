#ifndef DIBS_TIMEBASE_H_
#define DIBS_TIMEBASE_H_

#include <stdbool.h>
#include <stdint.h>

/*
 * Session clock: TIMER3 counting microseconds from the 32 MHz crystal, the
 * same crystal that clocks the PDM microphone, so audio sample times and this
 * clock never drift apart. Valid between timebase_start() and timebase_stop();
 * wraps after ~71.6 minutes (the phone unwraps it).
 */
int timebase_init(void);
int timebase_start(void);
void timebase_stop(void);
uint32_t timebase_now_us(void);

/* Arms a one-shot hardware capture of the PDM STARTED event, i.e. the moment
 * the microphone starts filling its first buffer. */
void timebase_arm_pdm_capture(void);
bool timebase_pdm_started_us(uint32_t *t_us);

/* Session time of the latest PDM END event (a 20 ms buffer filled). */
uint32_t timebase_pdm_end_us(void);

#endif /* DIBS_TIMEBASE_H_ */
