#include <unistd.h>
#include <fcntl.h>

#include "memory.h"
#include "fiber.h"
#include "unit.h"
#include "trivia/util.h"

static size_t stack_expand_limit;
static struct fiber_attr default_attr;

static unsigned long page_size;
#define PAGE_4K 4096
#define BUF_SIZE 1024

/** Total count of allocated fibers in the cord. Including dead ones. */
static int
fiber_count_total(void)
{
	size_t res = mempool_count(&cord()->fiber_mempool);
	assert(res <= INT_MAX);
	return (int)res;
}

static int
noop_f(va_list ap)
{
	return 0;
}

static int
cancel_f(va_list ap)
{
	while (true) {
		fiber_sleep(0.001);
		fiber_testcancel();
	}
	return 0;
}

static int
wait_cancel_f(va_list ap)
{
	while (!fiber_is_cancelled())
		fiber_yield();
	return 0;
}

static int
exception_f(va_list ap)
{
	tnt_raise(OutOfMemory, 42, "allocator", "exception");
	return 0;
}

static int
no_exception_f(va_list ap)
{
	try {
		tnt_raise(OutOfMemory, 42, "allocator", "exception");
	} catch (Exception *e) {
		;
	}
	return 0;
}

static int
cancel_dead_f(va_list ap)
{
	note("cancel dead has started");
	tnt_raise(OutOfMemory, 42, "allocator", "exception");
	return 0;
}

static void NOINLINE
stack_expand(unsigned long *ret, unsigned long nr_calls)
{
	char volatile fill[PAGE_4K];
	char volatile *p;

	memset((void *)fill, (unsigned char)nr_calls, sizeof(fill));
	p = fill;
	p[PAGE_4K / 2] = (unsigned char)nr_calls;

	if (nr_calls != 0) {
		stack_expand(ret, nr_calls-1);
	} else {
		*ret = (unsigned long)&fill[0];
	}
}

static int
test_stack_f(va_list ap)
{
	unsigned long ret = 0;
	unsigned long ret_addr = (unsigned long)&ret;

	/*
	 * We can't just dirty the stack in precise
	 * way without using assembly. Thus lets do
	 * the following trick:
	 *  - assume 8K will be enough to carry all
	 *    arguments passed for all calls, still
	 *    we might need to adjust this value
	 */
	stack_expand(&ret, (stack_expand_limit - 2 * page_size) / page_size);
	return 0;
}

static int
fib_ok_f(va_list ap)
{
	fiber_sleep(0.1);
	return 0;
}

static int
fib_err_f(va_list ap)
{
	diag_set(SystemError, "some error");
	return 42;
}

static int
waker_f(va_list ap)
{
	struct fiber *main_fiber = (struct fiber *)fiber()->f_arg;
	fiber_wakeup(main_fiber);
	return 0;
}

static int
canceller_f(va_list ap)
{
	struct fiber *main_fiber = (struct fiber *)fiber()->f_arg;
	fiber_cancel(main_fiber);
	return 0;
}

static int
watcher_f(va_list ap)
{
	fiber_sleep(1);
	if (fiber_is_cancelled())
		return 0;

	fail("watcher timeout", "triggered");
	unreachable();
}

static void
fiber_join_test()
{
	header();

	struct fiber *fiber = fiber_new_xc("join", noop_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	fiber_join(fiber);

	fiber = fiber_new_xc("cancel", cancel_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	fiber_sleep(0);
	fiber_cancel(fiber);
	fiber_join(fiber);

	fiber = fiber_new_xc("exception", exception_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	try {
		if (fiber_join(fiber) != 0)
			diag_raise();
		fail("exception not raised", "");
	} catch (Exception *e) {
		note("exception propagated");
	}

	fputs("#gh-1238: log uncaught errors\n", stderr);
	fiber = fiber_new_xc("exception", exception_f);
	fiber_wakeup(fiber);

	/*
	 * A fiber which is using exception should not
	 * push them up the stack.
	 */
	fiber = fiber_new_xc("no_exception", no_exception_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	fiber_join(fiber);
	/*
	 * Trying to cancel a dead joinable cancellable fiber lead to
	 * a crash, because cancel would try to schedule it.
	 */
	fiber = fiber_new_xc("cancel_dead", cancel_dead_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	/** Let the fiber schedule */
	fiber_reschedule();
	note("by this time the fiber should be dead already");
	fiber_cancel(fiber);
	fiber_join(fiber);

	note("Can change the joinability in safe cases.");
	fiber = fiber_new_xc("alive_not_joinable", noop_f);
	/* Non-joinable not dead fiber.  */
	fiber_set_joinable(fiber, true);
	fail_unless((fiber->flags & FIBER_IS_JOINABLE) != 0);
	/* Joinable not dead and not joined fiber. */
	fiber_set_joinable(fiber, false);
	fail_unless((fiber->flags & FIBER_IS_JOINABLE) == 0);
	/* The same as the first case , just to be sure. */
	fiber_set_joinable(fiber, true);
	fail_unless((fiber->flags & FIBER_IS_JOINABLE) != 0);
	fiber_wakeup(fiber);
	fiber_join(fiber);

	footer();
}

void
fiber_stack_test()
{
	header();

	struct fiber *fiber;
	struct fiber_attr *fiber_attr;
	struct slab_cache *slabc = &cord()->slabc;

	/*
	 * Test a fiber with the default stack size.
	 */
	stack_expand_limit = default_attr.stack_size * 3 / 4;
	fiber = fiber_new_xc("test_stack", test_stack_f);
	fiber_wakeup(fiber);
	fiber_sleep(0);
	note("normal-stack fiber not crashed");

	/*
	 * Test a fiber with a custom stack size.
	 */
	int fiber_count = fiber_count_total();
	size_t used1 = slab_cache_used(slabc);
	fiber_attr = fiber_attr_new();
	fiber_attr_setstacksize(fiber_attr, default_attr.stack_size * 2);
	stack_expand_limit = default_attr.stack_size * 3 / 2;
	fiber = fiber_new_ex("test_stack", fiber_attr, test_stack_f);
	fail_unless(fiber_count + 1 == fiber_count_total());
	fiber_attr_delete(fiber_attr);
	if (fiber == NULL)
		diag_raise();
	fiber_wakeup(fiber);
	fiber_sleep(0);
	cord_collect_garbage(cord());
	fail_unless(fiber_count == fiber_count_total());
	size_t used2 = slab_cache_used(slabc);
	fail_unless(used2 == used1);
	note("big-stack fiber not crashed");

	footer();
}

void
fiber_name_test()
{
	header();
	note("name of a new fiber: %s.\n", fiber_name(fiber()));

	fiber_set_name(fiber(), "Horace");

	note("set new fiber name: %s.\n", fiber_name(fiber()));

	char long_name[FIBER_NAME_MAX + 30];
	memset(long_name, 'a', sizeof(long_name));
	long_name[sizeof(long_name) - 1] = 0;

	fiber_set_name(fiber(), long_name);

	note("fiber name is truncated: %s.\n", fiber_name(fiber()));
	footer();
}

static void
fiber_wakeup_self_test()
{
	header();

	struct fiber *f = fiber();

	fiber_wakeup(f);
	double duration = 0.001;
	uint64_t t1 = fiber_clock64();
	fiber_sleep(duration);
	uint64_t t2 = fiber_clock64();
	/*
	 * It was a real sleep, not 0 duration. Wakeup is nop on the running
	 * fiber.
	 */
	assert(t2 - t1 >= duration);

	/*
	 * Wakeup + start of a new fiber. This is different from yield but
	 * works without crashes too.
	 */
	struct fiber *newf = fiber_new_xc("nop", noop_f);
	fiber_wakeup(f);
	fiber_start(newf);

	footer();
}

static void
fiber_wakeup_dead_test()
{
	header();

	struct fiber *fiber = fiber_new_xc("wakeup_dead", noop_f);
	fiber_set_joinable(fiber, true);
	fiber_start(fiber);
	fiber_wakeup(fiber);
	fiber_wakeup(fiber);
	fiber_join(fiber);

	footer();
}

static void
fiber_dead_while_in_cache_test(void)
{
	header();

	struct fiber *f = fiber_new_xc("nop", noop_f);
	int fiber_count = fiber_count_total();
	fiber_start(f);
	/* The fiber remains in the cache of recycled fibers. */
	fail_unless(fiber_count == fiber_count_total());
	fail_unless(fiber_is_dead(f));

	footer();
}

static void
fiber_flags_respect_test(void)
{
	header();

	/* Make sure the cache has at least one fiber. */
	struct fiber *f = fiber_new_xc("nop", noop_f);
	fiber_start(f);

	/* Fibers taken from the cache need to respect the passed flags. */
	struct fiber_attr attr;
	fiber_attr_create(&attr);
	uint32_t flags = FIBER_IS_JOINABLE;
	attr.flags |= flags;
	f = fiber_new_ex("wait_cancel", &attr, wait_cancel_f);
	fail_unless((f->flags & flags) == flags);
	fiber_wakeup(f);
	fiber_cancel(f);
	fiber_join(f);

	footer();
}

static void
fiber_wait_on_deadline_test()
{
	header();

	struct fiber *fiber = fiber_new_xc("noop", noop_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	bool exceeded = fiber_wait_on_deadline(fiber, fiber_clock() + 100.0);
	fail_if(exceeded);
	fail_if(!fiber_is_dead(fiber));
	fiber_join(fiber);

	fiber = fiber_new_xc("cancel", cancel_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	exceeded = fiber_wait_on_deadline(fiber, fiber_clock() + 0.001);
	fail_if(!exceeded);
	fail_if(fiber_is_dead(fiber));
	fiber_cancel(fiber);
	fiber_join(fiber);

	footer();
}

static void
cord_cojoin_test(void)
{
	header();

	struct cord cords[2];
	fail_if(cord_costart(&cords[0], "cord1", fib_ok_f, NULL) != 0);
	fail_if(cord_costart(&cords[1], "cord2", fib_err_f, NULL) != 0);

	/* Check that cord_cojoin is not interrupted by fiber_wakeup. */
	struct fiber *waker_fiber = fiber_new("waker", waker_f);
	fail_if(waker_fiber == NULL);
	waker_fiber->f_arg = fiber();
	fiber_wakeup(waker_fiber);

	/* cord_cojoin will yield till fib_ok_f completion. */
	fail_if(cord_cojoin(&cords[0]) != 0);
	fail_if(cord_cojoin(&cords[1]) != -1);

	footer();
}

static void
cord_cojoin_cancel_test(void)
{
	header();

	struct cord cord;
	fail_if(cord_costart(&cord, "cord", wait_cancel_f, NULL) != 0);

	struct fiber *canceller_fiber = fiber_new("canceller", canceller_f);
	fail_if(canceller_fiber == NULL);
	canceller_fiber->f_arg = fiber();
	fiber_wakeup(canceller_fiber);

	struct fiber *watcher_fiber = fiber_new("watcher", watcher_f);
	fail_if(watcher_fiber == NULL);
	fiber_set_joinable(watcher_fiber, true);
	fiber_wakeup(watcher_fiber);

	fail_if(cord_cojoin(&cord) != 0);

	fiber_cancel(watcher_fiber);
	fiber_join(watcher_fiber);

	footer();
}

static void
fiber_test_defaults()
{
	header();

#ifdef ENABLE_BACKTRACE
#ifndef NDEBUG
	fail_if(!fiber_leak_backtrace_enable);
#else
	fail_if(fiber_leak_backtrace_enable);
#endif
#endif

#ifdef ABORT_ON_LEAK
	fail_if(!fiber_abort_on_gc_leak);
#else
	fail_if(fiber_abort_on_gc_leak);
#endif

	footer();
}

static NOINLINE int
leaker_f(va_list ap)
{
	region_alloc(&fiber()->gc, 1);
	return 0;
}

static void
fiber_test_leak(bool backtrace_enabled)
{
	header();

#ifdef ENABLE_BACKTRACE
	bool leak_save = fiber_leak_backtrace_enable;
	fiber_leak_backtrace_enable = backtrace_enabled;
#endif
	bool abort_save = fiber_abort_on_gc_leak;
	fiber_abort_on_gc_leak = false;

	int fd = open("log.txt", O_RDONLY);
	fail_if(fd == -1);
	int rc = lseek(fd, 0, SEEK_END);
	fail_if(rc == -1);

	struct fiber *fiber = fiber_new_xc("leak", leaker_f);
	fiber_set_joinable(fiber, true);
	fiber_wakeup(fiber);
	fiber_join(fiber);

#ifdef ENABLE_BACKTRACE
	fiber_leak_backtrace_enable = leak_save;
#endif
	fiber_abort_on_gc_leak = abort_save;

	char buf[BUF_SIZE];
	rc = read(fd, buf, BUF_SIZE - 1);
	close(fd);
	fail_if(rc == -1);
	buf[rc] = '\0';

#ifdef ENABLE_BACKTRACE
	if (backtrace_enabled) {
		const char *msg = "Fiber gc leak is found. "
				  "First leaked fiber gc allocation"
				  " backtrace:";
		char *s = strstr(buf, msg);
		fail_unless(s != NULL);
		/*
		 * Do not test for `region_alloc` frame as it is inlined
		 * in release build.
		 */
		s = strstr(s, "leaker_f");
		fail_unless(s != NULL);
		s = strstr(s, "fiber_cxx_invoke");
		fail_unless(s != NULL);
	} else {
		const char *msg =
			"Fiber gc leak is found. "
			"Leak backtrace is not available. "
			"Make sure fiber.leak_backtrace_enable() is called"
			" before starting this fiber to obtain "
			" the backtrace.";
		char *s = strstr(buf, msg);
		fail_unless(s != NULL);
	}
#else
	const char *msg =
			"Fiber gc leak is found. "
			"Leak backtrace is not available on your platform.";
	char *s = strstr(buf, msg);
	fail_unless(s != NULL);
#endif

	footer();
}

static void
fiber_test_leak_modes()
{
	say_logger_init("log.txt", S_ERROR,
			/* nonblock =*/ 0, "plain");

	/*
	 * Run two times even when ENABLE_BACKTRACE is not defined as
	 * we have .result file.
	 */
	fiber_test_leak(/* backtrace_enabled =*/ true);
	fiber_test_leak(/* backtrace_enabled =*/ false);

	say_logger_free();
}

static void
fiber_test_client_fiber_count(void)
{
	header();

	int count = cord()->client_fiber_count;

	struct fiber *fiber1 = fiber_new("fiber1", wait_cancel_f);
	fail_unless(fiber1 != NULL);
	fail_unless(++count == cord()->client_fiber_count);

	struct fiber *fiber2 = fiber_new("fiber2", wait_cancel_f);
	fail_unless(fiber2 != NULL);
	fail_unless(++count == cord()->client_fiber_count);

	struct fiber *fiber3 = fiber_new_system("fiber3", wait_cancel_f);
	fail_unless(fiber3 != NULL);
	fail_unless(count == cord()->client_fiber_count);

	struct fiber *fiber4 = fiber_new_system("fiber4", wait_cancel_f);
	fail_unless(fiber4 != NULL);
	fail_unless(count == cord()->client_fiber_count);

	fiber_set_joinable(fiber1, true);
	fiber_cancel(fiber1);
	fiber_join(fiber1);
	fail_unless(--count == cord()->client_fiber_count);

	fiber_set_joinable(fiber4, true);
	fiber_cancel(fiber4);
	fiber_join(fiber4);
	fail_unless(count == cord()->client_fiber_count);

	fiber_set_joinable(fiber2, true);
	fiber_cancel(fiber2);
	fiber_join(fiber2);
	fail_unless(--count == cord()->client_fiber_count);

	fiber_set_joinable(fiber3, true);
	fiber_cancel(fiber3);
	fiber_join(fiber3);
	fail_unless(count == cord()->client_fiber_count);

	footer();
}

static void
fiber_test_set_system(void)
{
	header();

	struct fiber *fiber1 = fiber_new("fiber1", wait_cancel_f);
	fail_unless(fiber1 != NULL);
	int count = cord()->client_fiber_count;

	fiber_set_system(fiber1, true);
	fail_unless(--count == cord()->client_fiber_count);
	fail_unless((fiber1->flags & FIBER_IS_SYSTEM) != 0);

	fiber_set_system(fiber1, true);
	fail_unless(count == cord()->client_fiber_count);
	fail_unless((fiber1->flags & FIBER_IS_SYSTEM) != 0);

	fiber_set_system(fiber1, false);
	fail_unless(++count == cord()->client_fiber_count);
	fail_unless((fiber1->flags & FIBER_IS_SYSTEM) == 0);

	fiber_set_system(fiber1, false);
	fail_unless(count == cord()->client_fiber_count);
	fail_unless((fiber1->flags & FIBER_IS_SYSTEM) == 0);

	struct fiber *fiber2 = fiber_new_system("fiber2", wait_cancel_f);
	fail_unless(fiber2 != NULL);
	count = cord()->client_fiber_count;

	fiber_set_system(fiber2, false);
	fail_unless(++count == cord()->client_fiber_count);
	fail_unless((fiber2->flags & FIBER_IS_SYSTEM) == 0);

	fiber_set_system(fiber2, false);
	fail_unless(count == cord()->client_fiber_count);
	fail_unless((fiber2->flags & FIBER_IS_SYSTEM) == 0);

	fiber_set_system(fiber2, true);
	fail_unless(--count == cord()->client_fiber_count);
	fail_unless((fiber2->flags & FIBER_IS_SYSTEM) != 0);

	fiber_set_system(fiber2, true);
	fail_unless(count == cord()->client_fiber_count);
	fail_unless((fiber2->flags & FIBER_IS_SYSTEM) != 0);

	fiber_set_joinable(fiber1, true);
	fiber_cancel(fiber1);
	fiber_join(fiber1);
	fiber_set_joinable(fiber2, true);
	fiber_cancel(fiber2);
	fiber_join(fiber2);

	footer();
}

static int
sleeper_f(va_list ap)
{
	for (int i = 0; i < 5; i++)
		fiber_sleep(0.1);
	return 0;
}

static void
fiber_test_wait_dead(void)
{
	header();

	/* Test we can handle when fiber become invalid during dead wait. */
	struct fiber *fiber1 = fiber_new("fiber1", noop_f);
	uint64_t fid1 = fiber1->fid;
	fail_unless(fiber1 != NULL);
	fiber_wakeup(fiber1);
	fail_unless(fiber_wait_dead(fiber1, TIMEOUT_INFINITY));
	fail_unless(fiber_find(fid1) == NULL);

	/*
	 * Test we can handle spurious wakeups due to fiber yields
	 * during our dead wait.
	 */
	struct fiber *fiber2 = fiber_new("fiber2", sleeper_f);
	uint64_t fid2 = fiber2->fid;
	fail_unless(fiber2 != NULL);
	fiber_wakeup(fiber2);
	fail_unless(fiber_wait_dead(fiber2, TIMEOUT_INFINITY));
	fail_unless(fiber_find(fid2) == NULL);

	/* Test we can handle already dead fiber. */
	struct fiber *fiber3 = fiber_new("fiber3", noop_f);
	fail_unless(fiber3 != NULL);
	fiber_set_joinable(fiber3, true);
	fiber_wakeup(fiber3);
	fiber_sleep(0);
	fail_unless(fiber_is_dead(fiber3));
	fail_unless(fiber_wait_dead(fiber3, TIMEOUT_INFINITY));
	fiber_join(fiber3);

	/* Test we can handle death of joinable fiber. */
	struct fiber *fiber4 = fiber_new("fiber4", noop_f);
	fail_unless(fiber4 != NULL);
	fiber_set_joinable(fiber4, true);
	fiber_wakeup(fiber4);
	fail_unless(fiber_wait_dead(fiber3, TIMEOUT_INFINITY));
	fail_unless(fiber_is_dead(fiber4));
	fiber_join(fiber4);

	/* Test with timeout. */
	struct fiber *fiber5 = fiber_new("fiber4", wait_cancel_f);
	fail_unless(fiber5 != NULL);
	fiber_set_joinable(fiber5, true);
	fiber_wakeup(fiber5);
	fail_if(fiber_wait_dead(fiber3, 0.2));
	fail_if(fiber_is_dead(fiber5));
	fiber_cancel(fiber5);
	fiber_join(fiber5);

	footer();
}

static int
hang_on_cancel_f(va_list ap)
{
	while (!fiber_is_cancelled())
		fiber_yield();
	fiber_set_system(fiber(), true);
	while (true)
		fiber_yield();
	return 0;
}

static int
new_fiber_on_shudown_f(va_list ap)
{
	while (!fiber_is_cancelled())
		fiber_yield();
	struct fiber *fiber = fiber_new("fiber_on_shutdown", wait_cancel_f);
	fail_unless(fiber == NULL);
	fail_unless(!diag_is_empty(diag_get()));
	fail_unless(strcmp(diag_last_error(diag_get())->errmsg,
			   "fiber is cancelled") == 0);
	struct fiber *system_fiber =
			fiber_new_system("system_fiber_on_shutdown", noop_f);
	fail_unless(system_fiber != NULL);
	fiber_set_joinable(system_fiber, true);
	fiber_start(system_fiber);
	fiber_join(system_fiber);
	return 0;
}

static void
fiber_test_shutdown(void)
{
	header();

	struct fiber *fiber1 = fiber_new("fiber1", wait_cancel_f);
	fail_unless(fiber1 != NULL);
	fiber_set_joinable(fiber1, true);
	struct fiber *fiber2 = fiber_new_system("fiber2", wait_cancel_f);
	fail_unless(fiber2 != NULL);
	struct fiber *fiber3 = fiber_new("fiber3", hang_on_cancel_f);
	fail_unless(fiber3 != NULL);
	struct fiber *fiber4 = fiber_new("fiber4", new_fiber_on_shudown_f);
	fail_unless(fiber4 != NULL);
	fiber_set_joinable(fiber4, true);

	int rc = fiber_shutdown(1000.0);
	fail_unless(rc == 0);

	fail_unless((fiber1->flags & FIBER_IS_DEAD) != 0);
	fail_unless((fiber2->flags & FIBER_IS_DEAD) == 0);
	fail_unless((fiber3->flags & FIBER_IS_DEAD) == 0);
	fail_unless((fiber4->flags & FIBER_IS_DEAD) != 0);

	fiber_join(fiber1);
	fiber_join(fiber4);

	fiber_set_joinable(fiber2, true);
	fiber_cancel(fiber2);
	fiber_join(fiber2);

	struct fiber *fiber5 = fiber_new("fiber5", wait_cancel_f);
	fail_unless(fiber5 == NULL);
	fail_unless(!diag_is_empty(diag_get()));
	fail_unless(strcmp(diag_last_error(diag_get())->errmsg,
			   "fiber is cancelled") == 0);

	footer();
}

static int
main_f(va_list ap)
{
	fiber_name_test();
	fiber_join_test();
	fiber_stack_test();
	fiber_wakeup_self_test();
	fiber_wakeup_dead_test();
	fiber_dead_while_in_cache_test();
	fiber_flags_respect_test();
	fiber_wait_on_deadline_test();
	cord_cojoin_test();
	cord_cojoin_cancel_test();
	fiber_test_defaults();
	fiber_test_leak_modes();
	fiber_test_client_fiber_count();
	fiber_test_set_system();
	fiber_test_wait_dead();
	fiber_test_shutdown();
	ev_break(loop(), EVBREAK_ALL);
	return 0;
}

int main()
{
	page_size = sysconf(_SC_PAGESIZE);

	/* Page should be at least 4K */
	assert(page_size >= PAGE_4K);

	memory_init();
	fiber_init(fiber_cxx_invoke);
	fiber_attr_create(&default_attr);
	struct fiber *main = fiber_new_system_xc("main", main_f);
	fiber_wakeup(main);
	ev_run(loop(), 0);
	fiber_free();
	memory_free();
	return 0;
}
