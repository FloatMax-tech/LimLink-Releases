using LimLink.Updates;
namespace LimLink.Core.Tests;
public class UpdateScheduleTests {
    [Fact] public void AutomaticCheckIsOptOutAndOncePerDate() {
        var today = new DateOnly(2026,10,24);
        Assert.True(UpdateSchedule.ShouldCheck(true,null,today));
        Assert.False(UpdateSchedule.ShouldCheck(false,null,today));
        Assert.False(UpdateSchedule.ShouldCheck(true,today,today));
        Assert.True(UpdateSchedule.ShouldCheck(true,today.AddDays(-1),today));
        Assert.False(UpdateSchedule.ShouldCheck(true,today.AddDays(1),today));
    }
}
