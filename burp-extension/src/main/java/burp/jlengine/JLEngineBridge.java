/*
 * JL Engine Bridge — Burp Suite Montoya extension
 * Captures all proxy traffic and exposes it via a local REST API on 127.0.0.1:8888
 * so the JL Engine can query what Burp has seen.
 *
 * Endpoints:
 *   GET /ping                          — health check + history count
 *   GET /history?limit=50&filter=host  — recent traffic (add &bodies=1 for full req/resp)
 */
package burp.jlengine;

import burp.api.montoya.BurpExtension;
import burp.api.montoya.MontoyaApi;
import burp.api.montoya.proxy.http.*;
import burp.api.montoya.http.message.HttpHeader;
import burp.api.montoya.http.message.requests.HttpRequest;

import java.io.*;
import java.net.*;
import java.net.http.HttpClient;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;

public class JLEngineBridge implements BurpExtension {

    static final int BRIDGE_PORT    = 8899;
    static final int MAX_HISTORY    = 500;
    static final int MAX_BODY_BYTES = 10_240;  // 10 KB body cap per entry

    private MontoyaApi api;
    private volatile boolean bridgeRunning = false;
    private ServerSocket bridgeSocket;
    private ExecutorService bridgePool;

    private final Deque<TrafficEntry>  history     = new ArrayDeque<>();
    private final Object               historyLock = new Object();
    private final AtomicInteger        entrySeq    = new AtomicInteger(0);
    private final HttpClient           httpClient  = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build();
    private static final Set<String> REDACT_HEADER_NAMES = new HashSet<>(Arrays.asList(
            "cookie", "authorization", "proxy-authorization", "set-cookie", "x-api-key", "api-key"
    ));
    private static final Pattern REDACT_TOKEN_KV = Pattern.compile(
            "(?i)(sessionKey|sessionKeyLC|routingHint|cf_clearance|__cf_bm|_cfuvid|anthropic-device-id|activitySessionId|__ssid|g_state)=[^;\\s]*"
    );

    // ── Extension entry point ──────────────────────────────────────────────────

    @Override
    public void initialize(MontoyaApi api) {
        this.api = api;
        api.extension().setName("JL Engine Bridge");

        api.proxy().registerResponseHandler(new CaptureHandler());
        startBridgeServer();

        api.logging().logToOutput("[JL Engine Bridge] Listening on http://127.0.0.1:" + BRIDGE_PORT);
        api.logging().logToOutput("[JL Engine Bridge] Endpoints: /ping  /history?limit=N&filter=host&bodies=1");
    }

    // ── Traffic capture ────────────────────────────────────────────────────────

    static class TrafficEntry {
        int    id, statusCode, responseLength;
        long   timestamp;
        String url, method, host, comment, highlight;
        String requestBody, responseBody;
        Map<String,String> requestHeaders  = new LinkedHashMap<>();
        Map<String,String> responseHeaders = new LinkedHashMap<>();
    }

    class CaptureHandler implements ProxyResponseHandler {
        @Override
        public ProxyResponseReceivedAction handleResponseReceived(InterceptedResponse resp) {
            capture(resp);
            return ProxyResponseReceivedAction.continueWith(resp);
        }
        @Override
        public ProxyResponseToBeSentAction handleResponseToBeSent(InterceptedResponse resp) {
            return ProxyResponseToBeSentAction.continueWith(resp);
        }
    }

    void capture(InterceptedResponse resp) {
        HttpRequest req = resp.initiatingRequest();
        TrafficEntry e  = new TrafficEntry();

        e.id             = entrySeq.incrementAndGet();
        e.timestamp      = System.currentTimeMillis();
        e.url            = req.url();
        e.method         = req.method();
        e.host           = req.httpService().host();
        e.statusCode     = resp.statusCode();
        e.responseLength = resp.body().length();
        e.comment        = "";
        e.highlight      = "";

        for (HttpHeader h : req.headers())  e.requestHeaders.put(h.name(),  h.value());
        for (HttpHeader h : resp.headers()) e.responseHeaders.put(h.name(), h.value());

        byte[] rb = req.body().getBytes();
        byte[] sb = resp.body().getBytes();
        e.requestBody  = new String(Arrays.copyOf(rb, Math.min(rb.length, MAX_BODY_BYTES)), StandardCharsets.UTF_8);
        e.responseBody = new String(Arrays.copyOf(sb, Math.min(sb.length, MAX_BODY_BYTES)), StandardCharsets.UTF_8);

        synchronized (historyLock) {
            history.addLast(e);
            if (history.size() > MAX_HISTORY) history.removeFirst();
        }
    }

    // ── Bridge REST server ─────────────────────────────────────────────────────

    void startBridgeServer() {
        try {
            bridgeSocket = new ServerSocket();
            bridgeSocket.bind(new InetSocketAddress("127.0.0.1", BRIDGE_PORT), 16);
            bridgePool = Executors.newFixedThreadPool(4);
            bridgeRunning = true;
            Thread acceptLoop = new Thread(() -> {
                while (bridgeRunning) {
                    try {
                        Socket s = bridgeSocket.accept();
                        bridgePool.submit(() -> handleClient(s));
                    } catch (IOException e) {
                        if (bridgeRunning) api.logging().logToError("[JL Engine Bridge] accept error: " + e.getMessage());
                    }
                }
            }, "jl-engine-bridge-accept");
            acceptLoop.setDaemon(true);
            acceptLoop.start();
        } catch (IOException e) {
            api.logging().logToError("[JL Engine Bridge] Failed to start bridge server: " + e.getMessage());
        }
    }

    void handlePing(OutputStream out) throws IOException {
        int count;
        synchronized (historyLock) { count = history.size(); }
        respond(out, 200, "{\"status\":\"ok\",\"history_count\":" + count + ",\"port\":" + BRIDGE_PORT + "}");
    }

    void handleHistory(String method, String query, OutputStream out) throws IOException {
        if (!method.equalsIgnoreCase("GET")) {
            respond(out, 405, "{\"error\":\"GET only\"}");
            return;
        }
        Map<String,String> q      = parseQuery(query);
        int    limit              = Integer.parseInt(q.getOrDefault("limit", "50"));
        String filter             = q.getOrDefault("filter", "").toLowerCase();
        boolean includeBodies     = q.containsKey("bodies");

        List<TrafficEntry> snap;
        synchronized (historyLock) { snap = new ArrayList<>(history); }

        List<TrafficEntry> result = new ArrayList<>();
        for (int i = snap.size() - 1; i >= 0 && result.size() < limit; i--) {
            TrafficEntry e = snap.get(i);
            if (filter.isEmpty()
                    || e.host.toLowerCase().contains(filter)
                    || e.url.toLowerCase().contains(filter)) {
                result.add(e);
            }
        }
        Collections.reverse(result);

        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < result.size(); i++) {
            if (i > 0) sb.append(",");
            appendEntry(sb, result.get(i), includeBodies);
        }
        sb.append("]");
        respond(out, 200, sb.toString());
    }

    // ── JSON serialization ─────────────────────────────────────────────────────

    void appendEntry(StringBuilder sb, TrafficEntry e, boolean bodies) {
        sb.append("{");
        kv(sb, "id",       String.valueOf(e.id));       sb.append(",");
        kvs(sb, "url",     e.url);                      sb.append(",");
        kvs(sb, "method",  e.method);                   sb.append(",");
        kvs(sb, "host",    e.host);                     sb.append(",");
        kv(sb, "status",   String.valueOf(e.statusCode));sb.append(",");
        kv(sb, "length",   String.valueOf(e.responseLength)); sb.append(",");
        kv(sb, "timestamp",String.valueOf(e.timestamp));sb.append(",");
        kvs(sb, "comment", e.comment);                  sb.append(",");
        kvs(sb, "highlight", e.highlight);
        if (bodies) {
            sb.append(",\"request_headers\":").append(headersJson(e.requestHeaders));
            sb.append(",\"response_headers\":").append(headersJson(e.responseHeaders));
            sb.append(","); kvs(sb, "request_body",  e.requestBody);
            sb.append(","); kvs(sb, "response_body", e.responseBody);
        }
        sb.append("}");
    }

    void kv(StringBuilder sb, String k, String v)  { sb.append("\"").append(k).append("\":").append(v); }
    void kvs(StringBuilder sb, String k, String v) { sb.append("\"").append(k).append("\":").append(js(v)); }

    String headersJson(Map<String,String> h) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String,String> kv : h.entrySet()) {
            if (!first) sb.append(",");
            sb.append(js(kv.getKey())).append(":").append(js(sanitizeHeader(kv.getKey(), kv.getValue())));
            first = false;
        }
        return sb.append("}").toString();
    }

    String sanitizeHeader(String name, String value) {
        if (name == null) return value;
        String n = name.toLowerCase(Locale.ROOT);
        if (REDACT_HEADER_NAMES.contains(n)) {
            return "[REDACTED]";
        }
        if (value == null) return null;
        // Redact token-like key=value fragments that appear in non-cookie headers.
        return REDACT_TOKEN_KV.matcher(value).replaceAll("$1=[REDACTED]");
    }

    String js(String s) {
        if (s == null) return "null";
        return "\"" + s.replace("\\","\\\\").replace("\"","\\\"")
                       .replace("\n","\\n").replace("\r","\\r").replace("\t","\\t") + "\"";
    }

    Map<String,String> parseQuery(String query) {
        Map<String,String> m = new LinkedHashMap<>();
        if (query == null) return m;
        for (String p : query.split("&")) {
            String[] kv = p.split("=", 2);
            if (kv.length == 2)
                m.put(URLDecoder.decode(kv[0], StandardCharsets.UTF_8),
                      URLDecoder.decode(kv[1], StandardCharsets.UTF_8));
            else if (kv.length == 1)
                m.put(URLDecoder.decode(kv[0], StandardCharsets.UTF_8), "");
        }
        return m;
    }

    void respond(OutputStream out, int code, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        String status = switch (code) {
            case 200 -> "OK";
            case 405 -> "Method Not Allowed";
            case 404 -> "Not Found";
            default -> "Error";
        };
        String headers = "HTTP/1.1 " + code + " " + status + "\r\n"
                + "Content-Type: application/json\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Connection: close\r\n"
                + "Content-Length: " + bytes.length + "\r\n\r\n";
        out.write(headers.getBytes(StandardCharsets.UTF_8));
        out.write(bytes);
        out.flush();
    }

    void handleClient(Socket socket) {
        try (Socket s = socket;
             InputStream in = s.getInputStream();
             OutputStream out = s.getOutputStream();
             BufferedReader br = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {

            String requestLine = br.readLine();
            if (requestLine == null || requestLine.isEmpty()) return;
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) {
                respond(out, 400, "{\"error\":\"bad request\"}");
                return;
            }
            String method = parts[0];
            String target = parts[1];

            String line;
            while ((line = br.readLine()) != null && !line.isEmpty()) {
                // consume headers
            }

            String path = target;
            String query = null;
            int qidx = target.indexOf('?');
            if (qidx >= 0) {
                path = target.substring(0, qidx);
                query = target.substring(qidx + 1);
            }

            if ("/ping".equals(path)) {
                handlePing(out);
            } else if ("/history".equals(path)) {
                handleHistory(method, query, out);
            } else if ("/test_org_idor".equals(path)) {
                handleOrgIdorTest(method, query, out);
            } else {
                respond(out, 404, "{\"error\":\"not found\"}");
            }
        } catch (Exception e) {
            api.logging().logToError("[JL Engine Bridge] client error: " + e.getMessage());
        }
    }

    void handleOrgIdorTest(String method, String query, OutputStream out) throws IOException {
        if (!method.equalsIgnoreCase("GET")) {
            respond(out, 405, "{\"error\":\"GET only\"}");
            return;
        }
        Map<String,String> q = parseQuery(query);
        String replacementOrg = q.getOrDefault("org", "11111111-1111-1111-1111-111111111111");
        String contains = q.getOrDefault("contains", "/api/organizations/");
        int maxScan = Integer.parseInt(q.getOrDefault("scan", "300"));

        TrafficEntry base = null;
        synchronized (historyLock) {
            int seen = 0;
            Iterator<TrafficEntry> it = history.descendingIterator();
            while (it.hasNext() && seen < maxScan) {
                TrafficEntry e = it.next();
                seen++;
                if (!"GET".equalsIgnoreCase(e.method)) continue;
                if (!e.url.contains(contains)) continue;
                if (!e.url.contains("/api/organizations/")) continue;
                base = e;
                break;
            }
        }
        if (base == null) {
            respond(out, 404, "{\"status\":\"error\",\"error\":\"No matching GET request found in history\"}");
            return;
        }

        String mutatedUrl = base.url.replaceFirst("/api/organizations/[0-9a-fA-F\\-]+", "/api/organizations/" + replacementOrg);
        if (mutatedUrl.equals(base.url)) {
            respond(out, 400, "{\"status\":\"error\",\"error\":\"Could not mutate org UUID from selected request\"}");
            return;
        }

        try {
            java.net.http.HttpRequest.Builder rb = java.net.http.HttpRequest.newBuilder()
                    .uri(URI.create(mutatedUrl))
                    .timeout(Duration.ofSeconds(15))
                    .GET();

            for (Map.Entry<String,String> h : base.requestHeaders.entrySet()) {
                String name = h.getKey();
                String lname = name.toLowerCase(Locale.ROOT);
                if (lname.equals("host") || lname.equals("content-length") || lname.equals(":authority") || lname.equals("connection")) continue;
                rb.header(name, h.getValue());
            }

            HttpResponse<String> resp = httpClient.send(rb.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            String body = resp.body() == null ? "" : resp.body();
            String snippet = body.length() > 1200 ? body.substring(0, 1200) : body;

            StringBuilder sb = new StringBuilder("{");
            kvs(sb, "status", "ok"); sb.append(",");
            kv(sb, "base_id", String.valueOf(base.id)); sb.append(",");
            kvs(sb, "base_url", base.url); sb.append(",");
            kvs(sb, "mutated_url", mutatedUrl); sb.append(",");
            kv(sb, "mutated_status", String.valueOf(resp.statusCode())); sb.append(",");
            kvs(sb, "mutated_body_snippet", snippet);
            sb.append("}");
            respond(out, 200, sb.toString());
        } catch (Exception e) {
            respond(out, 500, "{\"status\":\"error\",\"error\":" + js(e.toString()) + "}");
        }
    }
}

