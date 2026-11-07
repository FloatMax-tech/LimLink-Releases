package com.limlink.kit.updates
import org.junit.Assert.*
import org.junit.Test
class UpdateScheduleTest {
    @Test fun automaticCheckIsOptOutAndOncePerDate() {
        assertTrue(UpdateSchedule.shouldCheck(true,null,"2026-10-24"))
        assertFalse(UpdateSchedule.shouldCheck(false,null,"2026-10-24"))
        assertFalse(UpdateSchedule.shouldCheck(true,"2026-10-24","2026-10-24"))
        assertTrue(UpdateSchedule.shouldCheck(true,"2026-10-23","2026-10-24"))
        assertFalse(UpdateSchedule.shouldCheck(true,"2026-10-25","2026-10-24"))
    }
}
