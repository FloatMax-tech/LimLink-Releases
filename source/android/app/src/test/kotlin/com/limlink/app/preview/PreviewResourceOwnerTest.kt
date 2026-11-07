package com.limlink.app.preview

import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class PreviewResourceOwnerTest {
    @Test fun dismissalDoesNotWaitForNativeRenderButEventuallyClosesExactlyOnce() {
        val worker = Executors.newSingleThreadExecutor()
        val renderer = Executors.newSingleThreadExecutor()
        val rendering = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val closes = AtomicInteger()
        try {
            val owner = PreviewResourceOwner(Closeable { closes.incrementAndGet(); closed.countDown() }, worker)
            renderer.submit { owner.use { rendering.countDown(); finish.await(5, TimeUnit.SECONDS) } }
            assertTrue(rendering.await(5, TimeUnit.SECONDS))
            val dismissal = Executors.newSingleThreadExecutor()
            try { dismissal.submit { owner.close(); owner.close() }.get(1, TimeUnit.SECONDS) }
            finally { dismissal.shutdownNow() }
            assertEquals(0, closes.get())
            finish.countDown()
            assertTrue(closed.await(5, TimeUnit.SECONDS))
            assertEquals(1, closes.get())
            assertThrows(IllegalStateException::class.java) { owner.use { } }
        } finally { finish.countDown(); worker.shutdownNow(); renderer.shutdownNow() }
    }
}
