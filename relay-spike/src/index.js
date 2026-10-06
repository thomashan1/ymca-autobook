// #138 relay spike, test 1: does a Fisikal session minted elsewhere work from
// Cloudflare's network? Read-only — lists occurrences, never joins or cancels.
const OCC = "https://ymca-silicon-valley.fisikal.com/api/web/schedule/occurrences";

export default {
  async fetch(req, env) {
    if (req.method !== "POST" || req.headers.get("x-spike-key") !== env.SPIKE_KEY) {
      return new Response("not found", { status: 404 });
    }
    const { cookies, csrf } = await req.json();
    const now = new Date();
    const iso = (d) => d.toISOString().replace(/\.\d{3}Z$/, "Z");
    const filter = { filter: [
      { by: "since", with: iso(now) },
      { by: "till", with: iso(new Date(now.getTime() + 2 * 86400e3)) },
    ] };
    const url = `${OCC}?json=${encodeURIComponent(JSON.stringify(filter))}&all_service_categories=true`;
    const t0 = Date.now();
    const r = await fetch(url, { headers: {
      cookie: cookies.map((c) => `${c.name}=${c.value}`).join("; "),
      "x-csrf-token": csrf,
      "x-requested-with": "XMLHttpRequest",
      accept: "*/*",
      referer: "https://ymca-silicon-valley.fisikal.com/",
      "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    }, redirect: "manual" });
    const ms = Date.now() - t0;
    const type = r.headers.get("content-type") || "";
    let count = null;
    if (type.includes("json")) count = ((await r.json()).data || []).length;
    const egress = await fetch("https://api.ipify.org?format=json").then((x) => x.json()).catch(() => ({}));
    return Response.json({
      status: r.status, contentType: type.slice(0, 40), occurrences: count, ms,
      colo: req.cf?.colo, egressIp: egress.ip ?? null,
    });
  },
};
