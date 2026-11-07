package com.limlink.kit.lan

import java.io.Closeable
import java.net.Socket
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/** A wall-clock budget for all blocking control I/O, independent of read activity. */
internal class ControlSocketDeadline(socket: Socket, scheduler: ScheduledExecutorService, timeoutMillis: Long = 120_000) : Closeable {
    private val expiration = scheduler.schedule({ runCatching { socket.close() } }, timeoutMillis, TimeUnit.MILLISECONDS)
    override fun close() { expiration.cancel(false) }
}
