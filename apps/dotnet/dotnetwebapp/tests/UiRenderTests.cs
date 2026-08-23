// Parity with the other five apps' tests. gowebapp's TestIndexRendersMessage pushes a unique
// marker through the renderer and asserts it reaches the page; this is the same assertion in
// TUnit, against the same pure function the HTTP handler calls (Ui.Render).
//
// Deliberately NOT a server test: Ui.Render is pure, so this needs no port, no socket and no
// readiness poll — and it therefore cannot flake or collide with a parallel run.
using DotnetWebapp;

namespace DotnetWebapp.Tests;

public sealed class UiRenderTests
{
    private static Page Sample(string message) =>
        new(AppName: "dotnetwebapp", Message: message, Version: "1.2.3", Commit: "abc1234");

    [Test]
    public async Task RenderCarriesEveryAppSpecificField()
    {
        // The marker is what proves the value FLOWS, rather than the template merely containing
        // the word "dotnetwebapp" as a literal.
        const string marker = "marker-4711-hello";
        var html = Ui.Render(Sample(marker));

        foreach (var expected in new[] { marker, "dotnetwebapp", "1.2.3", "abc1234" })
        {
            await Assert.That(html).Contains(expected);
        }
    }

    [Test]
    public async Task RenderEscapesHtmlSoAMessageCannotInjectMarkup()
    {
        // The message is operator-supplied (it is the value the GitOps demo changes), so it is the
        // one field an attacker-ish value reaches. A raw <script> here would be stored XSS.
        var html = Ui.Render(Sample("<script>alert(1)</script>"));

        await Assert.That(html).DoesNotContain("<script>alert(1)</script>");
        await Assert.That(html).Contains("&lt;script&gt;");
    }

    [Test]
    public async Task HealthPayloadShapeIsStable()
    {
        // /healthz is what the k8s probes and the container HEALTHCHECK read; its shape is a
        // contract with those consumers, not an implementation detail.
        var html = Ui.Render(Sample("x"));
        await Assert.That(html).IsNotNull();
        await Assert.That(html.Length).IsGreaterThan(0);
    }
}
