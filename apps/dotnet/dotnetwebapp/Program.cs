// dotnetwebapp — the .NET sibling of the other five apps.
//
// Serves the SAME contract so the pipeline, the ingress and `make verify` treat every app
// identically:
//
//   GET /         -> the landing page, whose greeting is the value we change to demo GitOps CD
//   GET /healthz  -> liveness/readiness (k8s probes + the container HEALTHCHECK)
//
// THE SHARED-UI CONTRACT: the markup below is byte-identical (modulo blank lines) to every other
// app's rendered page — `make check-ui-contract` renders all six and diffs them. Only the four
// app-specific fields differ. Do not "improve" the markup here; change it in all six or not at all.
//
// AIR-GAP: .NET is the THIN case. The app declares no PackageReference because ASP.NET Core's
// shared framework already carries Kestrel; the FRAMEWORK is the dependency and it ships inside the
// runtime image. Dockerfile.builder still does a real `dotnet restore` so the in-cluster build can
// run --no-restore and reach nuget.org never.
//
// Every operator-tunable value is env-driven with a documented default (mirrors .env.example).
using System.Net;
using System.Text;

namespace DotnetWebapp;

// AppVersion is the DECLARED semantic version, from the csproj <Version> baked into the assembly.
// It is a FIELD (not a static) so all six apps source it the SAME way and the ui-contract fixtures
// can set a placeholder; Version is the deployed IMAGE TAG.
public sealed record Page(string AppName, string Message, string AppVersion, string Version, string Commit);

public static class Ui
{
    // The demo "deploy me" value. `make verify` rewrites THIS line with a unique marker, pushes it,
    // and asserts the marker appears on the deployed page — the same trick it plays on javawebapp's
    // application.yml and gowebapp's main.go. Keep it on one line, in this exact shape.
    public const string DefaultMessage = "Hello from vks-airgap-cicd";

    /// <summary>Return the value of <paramref name="key"/>, or <paramref name="fallback"/> when unset/empty.</summary>
    public static string Env(string key, string fallback)
    {
        var v = Environment.GetEnvironmentVariable(key);
        return string.IsNullOrEmpty(v) ? fallback : v;
    }

    // Minimal escaping. Every field is interpolated into HTML and `make verify` injects a marker
    // into one of them; an unescaped '<' there would produce invalid markup and break the diff.
    private static string Esc(string s) => new StringBuilder(s)
        .Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
        .Replace("\"", "&#34;").Replace("'", "&#39;").ToString();

    public static string Render(Page p) => $$"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>{{Esc(p.AppName)}} — VKS CI/CD demo</title>
    <style>
        :root { color-scheme: light dark; }
        body {
            font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            margin: 0; min-height: 100vh; display: flex; align-items: center;
            justify-content: center; background: #0f172a; color: #e2e8f0;
        }
        .card {
            background: #1e293b; border-radius: 16px; padding: 2.5rem 3rem;
            box-shadow: 0 10px 40px rgba(0,0,0,.4); max-width: 40rem; width: 90%;
        }
        h1 { margin: 0 0 .25rem; font-size: 1.4rem; color: #94a3b8; font-weight: 600; }
        .message {
            font-size: 2rem; font-weight: 700; margin: .5rem 0 1.5rem;
            color: #38bdf8; word-break: break-word;
        }
        dl { display: grid; grid-template-columns: auto 1fr; gap: .4rem 1rem; margin: 0; }
        dt { color: #64748b; font-weight: 600; }
        dd { margin: 0; font-family: ui-monospace, "SFMono-Regular", Menlo, monospace; }
    </style>
</head>
<body>
    <main class="card">
        <h1>{{Esc(p.AppName)}}</h1>
        <p class="message">{{Esc(p.Message)}}</p>
        <dl>
            <dt>Version</dt><dd>{{Esc(p.AppVersion)}}</dd>
            <dt>Deployed tag</dt><dd>{{Esc(p.Version)}}</dd>
            <dt>Commit</dt><dd>{{Esc(p.Commit)}}</dd>
        </dl>
    </main>
</body>
</html>

""";

    public static Page FromEnv() => new(
        Env("APP_NAME", "dotnetwebapp"),
        Env("APP_MESSAGE", DefaultMessage),
        // The DECLARED version, from the csproj <Version> baked into the assembly at build time.
        // NOT env-overridable: APP_VERSION below already carries the deployed image tag (the sha).
        typeof(Page).Assembly.GetName().Version?.ToString(3) ?? "0.0.0",
        Env("APP_VERSION", "dev"),
        Env("APP_COMMIT", "unknown"));
}

public static class Program
{
    public static void Main(string[] args)
    {
        // THE SHARED-UI CONTRACT PRODUCER (see scripts/check-ui-contract.sh). Renders with the fixed
        // literals and exits — no socket, no restore of state. The literals must be IDENTICAL across
        // all six apps AND MUTUALLY DISTINCT: distinctness is the only reason a field SWAP
        // (AppName rendered where Version belongs) is caught by the diff.
        var contractOut = Environment.GetEnvironmentVariable("UI_CONTRACT_OUT");
        if (!string.IsNullOrEmpty(contractOut))
        {
            File.WriteAllText(contractOut, Ui.Render(new Page("APPNAME", "MESSAGE", "APPVERSION", "VERSION", "COMMIT")));
            return;
        }

        var p = Ui.FromEnv();
        var builder = WebApplication.CreateBuilder(args);
        builder.WebHost.UseUrls($"http://{Ui.Env("APP_BIND_HOST", "0.0.0.0")}:{Ui.Env("APP_INTERNAL_PORT", "8080")}");
        var app = builder.Build();

        app.MapGet("/healthz", () => Results.Content("{\"status\":\"UP\"}", "application/json", Encoding.UTF8, (int)HttpStatusCode.OK));
        app.MapGet("/", () => Results.Content(Ui.Render(p), "text/html", Encoding.UTF8, (int)HttpStatusCode.OK));
        app.Run();
    }
}
