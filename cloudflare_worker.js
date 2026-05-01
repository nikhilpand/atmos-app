/**
 * Atmos Stream Proxy - Cloudflare Worker
 * 
 * Instructions:
 * 1. Go to dash.cloudflare.com -> Workers & Pages -> Create Application -> Create Worker
 * 2. Name it `atmos-proxy` or similar.
 * 3. Copy this entire file into the Worker editor and click "Deploy".
 * 4. Update the Worker URL in the app's StreamExtractorService.
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // Support preflight CORS
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, HEAD, POST, OPTIONS",
          "Access-Control-Allow-Headers": "*",
        }
      });
    }

    const targetUrlBase64 = url.searchParams.get("url");
    if (!targetUrlBase64) {
      return new Response("Atmos Proxy Worker Online. Pass ?url=base64_target to proxy.", { 
        status: 200,
        headers: { "Content-Type": "text/plain" }
      });
    }

    let targetUrl;
    try {
      targetUrl = atob(targetUrlBase64);
    } catch (e) {
      return new Response("Invalid base64 in 'url' parameter", { status: 400 });
    }

    // Create the proxy request
    const targetRequest = new Request(targetUrl, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      redirect: "follow"
    });

    // We override headers to look like a normal browser from the origin
    targetRequest.headers.set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36");
    
    try {
      const parsedTargetUrl = new URL(targetUrl);
      targetRequest.headers.set("Referer", parsedTargetUrl.origin);
      targetRequest.headers.set("Origin", parsedTargetUrl.origin);
    } catch (e) {}

    try {
      const response = await fetch(targetRequest);
      
      // Clone response to modify headers
      const modifiedResponse = new Response(response.body, response);
      
      // Allow the app to access the response
      modifiedResponse.headers.set("Access-Control-Allow-Origin", "*");
      modifiedResponse.headers.delete("X-Frame-Options");
      modifiedResponse.headers.delete("Content-Security-Policy");

      return modifiedResponse;
    } catch (e) {
      return new Response(`Proxy Error: ${e.message}`, { status: 500 });
    }
  }
};
