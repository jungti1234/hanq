#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#include <stdint.h>
#include <mach/mach_time.h>
int hanq_metrics(uint64_t *values) {
    struct rusage_info_v4 info = {0};
    struct rusage peak = {0};
    int result = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&info);
    getrusage(RUSAGE_SELF, &peak);
    values[0] = info.ri_resident_size; values[1] = info.ri_phys_footprint;
    values[2] = info.ri_diskio_byteswritten; values[3] = peak.ru_maxrss;
    mach_timebase_info_data_t clock; mach_timebase_info(&clock);
    values[4] = (long double)info.ri_user_time * clock.numer / clock.denom;
    values[5] = (long double)info.ri_system_time * clock.numer / clock.denom;
    values[6] = info.ri_lifetime_max_phys_footprint;
    return result;
}
