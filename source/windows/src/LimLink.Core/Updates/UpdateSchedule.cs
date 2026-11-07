namespace LimLink.Updates;
public static class UpdateSchedule {
    public static bool ShouldCheck(bool enabled, DateOnly? lastAttempt, DateOnly today) => enabled && (lastAttempt is null || lastAttempt < today);
}
