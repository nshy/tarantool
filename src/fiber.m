/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include "fiber.h"
#include "config.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>
#include <sysexits.h>
#include <third_party/queue.h>
#include <assoc.h>

#include <palloc.h>
#include <salloc.h>
#include <say.h>
#include <tarantool.h>
#include TARANTOOL_CONFIG
#include <tarantool_ev.h>
#include <tbuf.h>
#include <util.h>
#include <stat.h>
#include <pickle.h>
#include "coio_buf.h"

@implementation FiberCancelException
@end

enum { FIBER_CALL_STACK = 16 };

static struct fiber sched;
__thread struct fiber *fiber = &sched;
static __thread struct fiber *call_stack[FIBER_CALL_STACK];
static __thread struct fiber **sp;
static __thread uint32_t last_used_fid;
static __thread struct palloc_pool *ex_pool;
static __thread struct mh_i32ptr_t *fibers_registry;
__thread SLIST_HEAD(, fiber) fibers, zombie_fibers;

struct fiber_cleanup {
	void (*handler) (void *data);
	void *data;
};

struct fiber_server {
	int port;
	void *data;
	void (*handler) (va_list ap);
	void (*on_bind) (void *data);
};

static void
update_last_stack_frame(struct fiber *fiber)
{
#ifdef ENABLE_BACKTRACE
	fiber->last_stack_frame = __builtin_frame_address(0);
#else
	(void)fiber;
#endif /* ENABLE_BACKTRACE */
}

void
fiber_call(struct fiber *callee, ...)
{
	struct fiber *caller = fiber;

	assert(sp - call_stack < FIBER_CALL_STACK);
	assert(caller);

	fiber = callee;
	*sp++ = caller;

	update_last_stack_frame(caller);

	callee->csw++;

	va_start(fiber->f_data, callee);
	coro_transfer(&caller->coro.ctx, &callee->coro.ctx);
	va_end(fiber->f_data);
}


/** Interrupt a synchronous wait of a fiber inside the event loop.
 * We do so by keeping an "async" event in every fiber, solely
 * for this purpose, and raising this event here.
 */

void
fiber_wakeup(struct fiber *f)
{
	ev_async_send(&f->async);
}

/** Cancel the subject fiber.
 *
 * Note: this is not guaranteed to succeed, and requires a level
 * of cooperation on behalf of the fiber. A fiber may opt to set
 * FIBER_CANCELLABLE to false, and never test that it was
 * cancelled.  Such fiber can not ever be cancelled, and
 * for such fiber this call will lead to an infinite wait.
 * However, fiber_testcancel() is embedded to the rest of fiber_*
 * API (@sa fiber_yield()), which makes most of the fibers that opt in,
 * cancellable.
 *
 * Currently cancellation can only be synchronous: this call
 * returns only when the subject fiber has terminated.
 *
 * The fiber which is cancelled, has FiberCancelException raised
 * in it. For cancellation to work, this exception type should be
 * re-raised whenever (if) it is caught.
 */

void
fiber_cancel(struct fiber *f)
{
	assert(f->fid != 0);
	assert(!(f->flags & FIBER_CANCEL));

	f->flags |= FIBER_CANCEL;

	if (f == fiber) {
		fiber_testcancel();
		return;
	}
	/*
	 * The subject fiber is passing through a wait
	 * point and can be kicked out of it right away.
	 */
	if (f->flags & FIBER_CANCELLABLE)
		fiber_call(f);

	if (f->fid) {
		/*
		 * The fiber is not dead. We have no other
		 * choice but wait for it to discover that
		 * it has been cancelled, and die.
		 */
		assert(f->waiter == NULL);
		f->waiter = fiber;
		fiber_yield();
	}
	/*
	 * Here we can't even check f->fid is 0 since
	 * f could have already been reused. Knowing
	 * at least that we can't get scheduled ourselves
	 * unless asynchronously woken up is somewhat a relief.
	 */

	fiber_testcancel(); /* Check if we're ourselves cancelled. */
}

bool
fiber_is_cancelled()
{
	return fiber->flags & FIBER_CANCEL;
}

/** Test if this fiber is in a cancellable state and was indeed
 * cancelled, and raise an exception (FiberCancelException) if
 * that's the case.
 */

void
fiber_testcancel(void)
{
	if (fiber_is_cancelled())
		tnt_raise(FiberCancelException);
}



/** Change the current cancellation state of a fiber. This is not
 * a cancellation point.
 */
bool
fiber_setcancellable(bool enable)
{
	bool prev = fiber->flags & FIBER_CANCELLABLE;
	if (enable == true)
		fiber->flags |= FIBER_CANCELLABLE;
	else
		fiber->flags &= ~FIBER_CANCELLABLE;
	return prev;
}

/**
 * @note: this is not a cancellation point (@sa fiber_testcancel())
 * but it is considered good practice to call testcancel()
 * after each yield.
 */
void
fiber_yield(void)
{
	struct fiber *callee = *(--sp);
	struct fiber *caller = fiber;

	fiber = callee;
	update_last_stack_frame(caller);

	callee->csw++;
	coro_transfer(&caller->coro.ctx, &callee->coro.ctx);
}

void
fiber_yield_to(struct fiber *f)
{
	fiber_wakeup(f);
	fiber_yield();
	fiber_testcancel();
}

/**
 * @note: this is a cancellation point (@sa fiber_testcancel())
 */

void
fiber_sleep(ev_tstamp delay)
{
	ev_timer_set(&fiber->timer, delay, 0.);
	ev_timer_start(&fiber->timer);
	fiber_yield();
	ev_timer_stop(&fiber->timer);
	fiber_testcancel();
}

/** Wait for a forked child to complete.
 * @note: this is a cancellation point (@sa fiber_testcancel()).
*/

void
wait_for_child(pid_t pid)
{
	ev_child_set(&fiber->cw, pid, 0);
	ev_child_start(&fiber->cw);
	fiber_yield();
	ev_child_stop(&fiber->cw);
	fiber_testcancel();
}

void
fiber_schedule(ev_watcher *watcher, int event __attribute__((unused)))
{
	assert(fiber == &sched);
	fiber_call(watcher->data);
}

struct fiber *
fiber_find(int fid)
{
	mh_int_t k = mh_i32ptr_get(fibers_registry, fid);

	if (k == mh_end(fibers_registry))
		return NULL;
	if (!mh_exist(fibers_registry, k))
		return NULL;
	return mh_value(fibers_registry, k);
}

static void
register_fid(struct fiber *fiber)
{
	int ret;
	mh_i32ptr_put(fibers_registry, fiber->fid, fiber, &ret);
}

static void
unregister_fid(struct fiber *fiber)
{
	mh_int_t k = mh_i32ptr_get(fibers_registry, fiber->fid);
	mh_i32ptr_del(fibers_registry, k);
}

static void
fiber_alloc(struct fiber *fiber)
{
	prelease(fiber->gc_pool);
	tbuf_init(&fiber->rbuf, fiber->gc_pool);
	tbuf_init(&fiber->iov, fiber->gc_pool);
	tbuf_init(&fiber->cleanup, fiber->gc_pool);
	fiber->iov_cnt = 0;
}

void
fiber_register_cleanup(fiber_cleanup_handler handler, void *data)
{
	struct fiber_cleanup i;
	i.handler = handler;
	i.data = data;
	tbuf_append(&fiber->cleanup, &i, sizeof(struct fiber_cleanup));
}

void
fiber_cleanup(void)
{
	struct fiber_cleanup *cleanup = fiber->cleanup.data;
	int i = fiber->cleanup.size / sizeof(struct fiber_cleanup);

	while (i-- > 0) {
		cleanup->handler(cleanup->data);
		cleanup++;
	}
	tbuf_reset(&fiber->cleanup);
}

void
fiber_gc(void)
{
	struct palloc_pool *tmp;

	fiber_cleanup();

	if (palloc_allocated(fiber->gc_pool) < 128 * 1024)
		return;

	tmp = fiber->gc_pool;
	fiber->gc_pool = ex_pool;
	ex_pool = tmp;
	palloc_set_name(fiber->gc_pool, fiber->name);
	palloc_set_name(ex_pool, "ex_pool");

	struct tbuf tmp_rbuf = fiber->rbuf;
	tbuf_init(&fiber->rbuf, fiber->gc_pool);
	tbuf_append(&fiber->rbuf, tmp_rbuf.data, tmp_rbuf.size);

	assert(fiber->iov_cnt == 0);
	tbuf_init(&fiber->iov, fiber->gc_pool);
	tbuf_init(&fiber->cleanup, fiber->gc_pool);

	prelease(ex_pool);
}


/** Destroy the currently active fiber and prepare it for reuse.
 */

static void
fiber_zombificate()
{
	if (fiber->waiter)
		fiber_wakeup(fiber->waiter);
	fiber->waiter = NULL;
	fiber_set_name(fiber, "zombie");
	fiber->f = NULL;
	unregister_fid(fiber);
	fiber->fid = 0;
	fiber->flags = 0;
	fiber_alloc(fiber);

	SLIST_INSERT_HEAD(&zombie_fibers, fiber, zombie_link);
}

static void
fiber_loop(void *data __attribute__((unused)))
{
	for (;;) {
		assert(fiber != NULL && fiber->f != NULL && fiber->fid != 0);
		@try {
			fiber->f(fiber->f_data);
		} @catch (FiberCancelException *e) {
			say_info("fiber `%s' has been cancelled", fiber->name);
			say_info("fiber `%s': exiting", fiber->name);
		} @catch (tnt_Exception *e) {
			[e log];
		} @catch (id e) {
			say_error("fiber `%s': exception `%s'", fiber->name, object_getClassName(e));
			panic("fiber `%s': exiting", fiber->name);
		}
		tbuf_reset(&fiber->rbuf);
		fiber_zombificate();
		fiber_yield();	/* give control back to scheduler */
	}
}

/** Set fiber name.
 *
 * @param[in] name the new name of the fiber. Truncated to
 * FIBER_NAME_MAXLEN.
*/

void
fiber_set_name(struct fiber *fiber, const char *name)
{
	assert(name != NULL);
	snprintf(fiber->name, sizeof(fiber->name), "%s", name);
	palloc_set_name(fiber->gc_pool, fiber->name);
}

/* fiber never dies, just become zombie */
struct fiber *
fiber_create(const char *name, void (*f) (va_list))
{
	struct fiber *fiber = NULL;

	if (!SLIST_EMPTY(&zombie_fibers)) {
		fiber = SLIST_FIRST(&zombie_fibers);
		SLIST_REMOVE_HEAD(&zombie_fibers, zombie_link);
	} else {
		fiber = palloc(eter_pool, sizeof(*fiber));
		if (fiber == NULL)
			return NULL;

		memset(fiber, 0, sizeof(*fiber));
		if (tarantool_coro_create(&fiber->coro, fiber_loop, NULL) == NULL)
			return NULL;

		fiber->gc_pool = palloc_create_pool("");

		fiber_alloc(fiber);
		ev_async_init(&fiber->async, (void *)fiber_schedule);
		ev_async_start(&fiber->async);
		ev_init(&fiber->timer, (void *)fiber_schedule);
		ev_init(&fiber->cw, (void *)fiber_schedule);
		fiber->async.data = fiber->timer.data = fiber->cw.data = fiber;

		SLIST_INSERT_HEAD(&fibers, fiber, link);
	}

	fiber->f = f;
	while (++last_used_fid <= 100) ;	/* fids from 0 to 100 are reserved */
	fiber->fid = last_used_fid;
	fiber->flags = 0;
	fiber->waiter = NULL;
	fiber_set_name(fiber, name);
	register_fid(fiber);

	return fiber;
}

/*
 * note, we can't release memory allocated via palloc(eter_pool, ...)
 * so, struct fiber and some of its members are leaked forever
 */

void
fiber_destroy(struct fiber *f)
{
	if (f == fiber) /* do not destroy running fiber */
		return;
	if (strcmp(f->name, "sched") == 0)
		return;

	ev_async_stop(&f->async);
	palloc_destroy_pool(f->gc_pool);
	tarantool_coro_destroy(&f->coro);
}

void
fiber_destroy_all()
{
	struct fiber *f;
	SLIST_FOREACH(f, &fibers, link)
		fiber_destroy(f);
}

void
iov_reset()
{
	fiber->iov_cnt = 0;	/* discard anything unwritten */
	tbuf_reset(&fiber->iov);
}

/**
 * @note: this is a cancellation point.
 */

ssize_t
iov_flush(struct coio *coio)
{
	struct iovec *iov = iovec(&fiber->iov);
	size_t iov_cnt = fiber->iov_cnt;

	ssize_t nwr = coio_writev(coio, iov, iov_cnt);
	iov_reset();
	return nwr;
}

void
fiber_info(struct tbuf *out)
{
	struct fiber *fiber;

	tbuf_printf(out, "fibers:" CRLF);
	SLIST_FOREACH(fiber, &fibers, link) {
		void *stack_top = fiber->coro.stack + fiber->coro.stack_size;

		tbuf_printf(out, "  - fid: %4i" CRLF, fiber->fid);
		tbuf_printf(out, "    csw: %i" CRLF, fiber->csw);
		tbuf_printf(out, "    name: %s" CRLF, fiber->name);
		tbuf_printf(out, "    stack: %p" CRLF, stack_top);
#ifdef ENABLE_BACKTRACE
		tbuf_printf(out, "    backtrace:" CRLF "%s",
			    backtrace(fiber->last_stack_frame,
				      fiber->coro.stack, fiber->coro.stack_size));
#endif /* ENABLE_BACKTRACE */
	}
}

void
fiber_init(void)
{
	SLIST_INIT(&fibers);
	fibers_registry = mh_i32ptr_init();

	ex_pool = palloc_create_pool("ex_pool");

	memset(&sched, 0, sizeof(sched));
	sched.fid = 1;
	sched.gc_pool = palloc_create_pool("");
	fiber_set_name(&sched, "sched");

	sp = call_stack;
	fiber = &sched;
	last_used_fid = 100;

	coio_binit(cfg.readahead);
}

void
fiber_free(void)
{
	/* Only clean up if initialized. */
	if (fibers_registry) {
		fiber_destroy_all();
		mh_i32ptr_destroy(fibers_registry);
	}
}
