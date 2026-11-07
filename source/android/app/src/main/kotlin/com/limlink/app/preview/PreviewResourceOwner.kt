package com.limlink.app.preview

import java.io.Closeable
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private object PreviewCleanup {
    val executor: Executor = Executors.newFixedThreadPool(2) { task -> Thread(task, "limlink-preview-cleanup").apply { isDaemon = true } }
}

/** close() never waits on a native render and its cleanup outlives the disposed UI coroutine. */
class PreviewResourceOwner<T : Closeable>(private val resource: T, private val executor: Executor = PreviewCleanup.executor) : Closeable {
    private val monitor = Any()
    private val closing = AtomicBoolean(false)
    fun <R> use(block: (T) -> R): R = synchronized(monitor) { check(!closing.get()); block(resource) }
    override fun close() {
        if (closing.compareAndSet(false, true)) executor.execute { synchronized(monitor) { runCatching { resource.close() } }; Unit }
    }
}
