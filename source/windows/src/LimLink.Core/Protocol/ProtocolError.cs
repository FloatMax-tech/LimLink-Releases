using System.Text.Json;
using System.Text.Json.Serialization;

namespace LimLink;

public sealed class ProtocolError
{
    public required string Code { get; init; }
    public required string Message { get; init; }
    public required bool Retryable { get; init; }
    public JsonElement? Detail { get; init; }

    public string? DetailApp
    {
        get
        {
            if (Detail is not { ValueKind: JsonValueKind.Object } detail)
            {
                return null;
            }

            return detail.TryGetProperty("app", out var app) && app.ValueKind == JsonValueKind.String
                ? app.GetString()
                : null;
        }
    }
}

public static class ProtocolJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static ProtocolError Error(string code, string message, bool retryable, object? detail = null)
    {
        JsonElement? element = null;
        if (detail is not null)
        {
            element = JsonSerializer.SerializeToElement(detail, Options);
        }

        return new ProtocolError
        {
            Code = code,
            Message = message,
            Retryable = retryable,
            Detail = element,
        };
    }
}
