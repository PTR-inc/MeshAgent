/*
 * Contention test for the inline ILibSpinLock in microstack/ILibParsers.h.
 *
 * Several threads hammer one lock. Inside the critical section each thread records itself as the
 * holder, does a read-modify-write on a shared counter with a deliberate gap between the read and
 * the write, and checks that it is still the holder before releasing. A lock that lets two threads
 * in at once fails the holder check at once and ends with a short counter. A pair of fields written
 * together under the lock must always read equal, which is what a release barrier on unlock is for.
 *
 * Build and run, from the repo root:
 *   Windows:  cl /nologo /O2 /DWIN32 /DMICROSTACK_NO_STDAFX /I microstack test\spinlock-test.c
 *   Linux:    gcc -O2 -pthread -D_POSIX -I microstack test/spinlock-test.c -o spinlock-test
 * Add -DSPINLOCK_TEST_OLD_BUG to build against a copy of the pre-fix Windows lock loop, which
 * inverted the InterlockedCompareExchange test, and watch the test fail. That is the sensitivity
 * check for the test itself.
 *
 * The ILIBCHAIN_GLOBAL_LOCK variant lives in ILibParsers.c and is not covered here.
 */
#if defined(WIN32) && !defined(MICROSTACK_NO_STDAFX)
#define MICROSTACK_NO_STDAFX
#endif
#include "ILibParsers.h"
#include <stdio.h>
#include <stdlib.h>

#ifdef WIN32
typedef HANDLE thread_t;
#define THREAD_FN(name) DWORD WINAPI name(void *arg)
#define THREAD_RET_VALUE 0
#else
typedef pthread_t thread_t;
#define THREAD_FN(name) void* name(void *arg)
#define THREAD_RET_VALUE NULL
#endif

#define THREADS 8
#define ITERATIONS 200000

#ifdef SPINLOCK_TEST_OLD_BUG
/* The Windows lock loop as it was before the fix. InterlockedCompareExchange returns the previous
 * value, so this exits at once when the lock is already held and spins once when it is free. */
#ifdef WIN32
static void old_lock(ILibSpinLock *lock)
{
	while (!InterlockedCompareExchange(lock, 1, 0)) { YieldProcessor(); }
}
#define LOCK(l)   old_lock(l)
#else
#error SPINLOCK_TEST_OLD_BUG reproduces the old Windows loop only
#endif
#else
#define LOCK(l)   ILibSpinLock_Lock(l)
#endif
#define UNLOCK(l) ILibSpinLock_UnLock(l)

static ILibSpinLock g_lock;
static volatile long g_counter;
static volatile long g_holder = -1;
static volatile long g_pairA, g_pairB;
static volatile long g_holderViolations, g_pairViolations;

static THREAD_FN(worker)
{
	long me = (long)(size_t)arg;
	long i;
	for (i = 0; i < ITERATIONS; ++i)
	{
		long v, k;
		LOCK(&g_lock);
		if (g_holder != -1) { ++g_holderViolations; }
		g_holder = me;
		if (g_pairA != g_pairB) { ++g_pairViolations; }
		v = g_counter;
		/* Widen the window between the read and the write so an unprotected section overlaps. */
		for (k = 0; k < 20; ++k) { v += (k & 1); v -= (k & 1); }
		g_counter = v + 1;
		g_pairA = v + 1;
		g_pairB = v + 1;
		if (g_holder != me) { ++g_holderViolations; }
		g_holder = -1;
		UNLOCK(&g_lock);
	}
	return THREAD_RET_VALUE;
}

int main(void)
{
	thread_t threads[THREADS];
	long t;
	long expected = (long)THREADS * ITERATIONS;
	int failed = 0;

	ILibSpinLock_Init(&g_lock);

	/* Uncontended acquire and release must leave the lock word free again. */
	LOCK(&g_lock);
	if (g_lock != 1) { printf("FAIL lock word is %ld after Lock, expected 1\n", (long)g_lock); failed = 1; }
	UNLOCK(&g_lock);
	if (g_lock != 0) { printf("FAIL lock word is %ld after UnLock, expected 0\n", (long)g_lock); failed = 1; }

	for (t = 0; t < THREADS; ++t)
	{
#ifdef WIN32
		threads[t] = CreateThread(NULL, 0, worker, (void*)(size_t)t, 0, NULL);
		if (threads[t] == NULL) { printf("CreateThread failed\n"); return 2; }
#else
		if (pthread_create(&threads[t], NULL, worker, (void*)(size_t)t) != 0) { printf("pthread_create failed\n"); return 2; }
#endif
	}
	for (t = 0; t < THREADS; ++t)
	{
#ifdef WIN32
		WaitForSingleObject(threads[t], INFINITE);
		CloseHandle(threads[t]);
#else
		pthread_join(threads[t], NULL);
#endif
	}

	if (g_counter != expected) { printf("FAIL counter is %ld, expected %ld (lost %ld updates)\n", (long)g_counter, expected, expected - (long)g_counter); failed = 1; }
	if (g_holderViolations != 0) { printf("FAIL %ld times a thread found another thread inside the critical section\n", (long)g_holderViolations); failed = 1; }
	if (g_pairViolations != 0) { printf("FAIL %ld times the paired fields disagreed after acquire\n", (long)g_pairViolations); failed = 1; }
	if (g_lock != 0) { printf("FAIL lock word is %ld at the end, expected 0\n", (long)g_lock); failed = 1; }

	if (failed == 0) { printf("PASS %d threads x %d iterations, counter %ld, no violations\n", THREADS, ITERATIONS, (long)g_counter); }
	return failed;
}
