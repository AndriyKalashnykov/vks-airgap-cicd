// The icon route must answer at the path the RENDERED PAGE points to — extracted from the page,
// never typed as a literal here.
//
// `make check-ui-contract` proves href="/favicon.svg" is byte-identical in all six apps and this
// proves a route answers; nothing else JOINS those two strings, so a hardcoded path here would let
// a route registered elsewhere pass both gates over a broken image.
//
// Over a REAL socket against Program.Build — not WebApplicationFactory, which would need
// Microsoft.AspNetCore.Mvc.Testing, a package the OFFLINE builder's NuGet cache does not carry.
using System.Text.RegularExpressions;
using DotnetWebapp;

namespace DotnetWebapp.Tests;

public sealed class IconRouteTests
{
    [Test]
    public async Task IconRouteAnswersAtTheHrefThePageRenders()
    {
        var p = new Page(AppName: "dotnetwebapp", Message: "m", Version: "v", Commit: "c");
        // Port 0: the OS picks a free one, so this cannot collide with a parallel run.
        var app = Program.Build(p, "http://127.0.0.1:0");
        await app.StartAsync();
        try
        {
            var baseUrl = app.Urls.First();
            using var http = new HttpClient();

            var body = await http.GetStringAsync($"{baseUrl}/");
            var m = Regex.Match(body, "<link rel=\"icon\"[^>]*href=\"([^\"]+)\"");
            await Assert.That(m.Success).IsTrue();
            var href = m.Groups[1].Value;

            var res = await http.GetAsync($"{baseUrl}{href}");
            await Assert.That((int)res.StatusCode).IsEqualTo(200);
            await Assert.That(res.Content.Headers.ContentType!.MediaType).IsEqualTo("image/svg+xml");
            // Compared against the app's OWN constant, so the colour lives in exactly ONE place.
            await Assert.That(await res.Content.ReadAsStringAsync()).IsEqualTo(Ui.Icon);
            await Assert.That(body).Contains($"src=\"{href}\"");
        }
        finally
        {
            await app.StopAsync();
        }
    }
}
