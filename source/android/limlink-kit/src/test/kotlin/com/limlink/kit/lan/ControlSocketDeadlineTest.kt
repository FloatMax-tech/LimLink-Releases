package com.limlink.kit.lan

import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import org.junit.Assert.*
import org.junit.Test

class ControlSocketDeadlineTest {
    @Test fun activeByteDripsCannotExtendTheWholeControlBudget() {
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress()).use { listener ->
            val sender = Thread {
                runCatching {
                    listener.accept().use { socket ->
                        val output = socket.getOutputStream()
                        for (byte in "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n{}".toByteArray()) {
                            output.write(byte.toInt()); output.flush(); Thread.sleep(25)
                        }
                    }
                }
            }.apply { isDaemon = true; start() }
            try {
                Socket(java.net.InetAddress.getLoopbackAddress(), listener.localPort).use { socket ->
                    // Each byte arrives before the ordinary socket idle timeout.
                    socket.soTimeout = 200
                    val started = System.nanoTime()
                    ControlSocketDeadline(socket, scheduler, 150).use {
                        assertThrows(IOException::class.java) { Wire.read(socket.getInputStream(), 16_384) }
                    }
                    assertTrue(socket.isClosed)
                    assertTrue(java.util.concurrent.TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 900)
                }
            } finally { scheduler.shutdownNow(); sender.join(2_000) }
        }
    }
}
