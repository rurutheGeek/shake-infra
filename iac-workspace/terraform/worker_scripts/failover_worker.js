export default {
  async fetch(request, env, ctx) {
    const html = `__MAINTENANCE_HTML_CONTENT__`;
    return new Response(html, {
      status: 503,
      headers: {
        "content-type": "text/html;charset=UTF-8",
        "retry-after": "3600" // 1時間後にリトライを促す
      },
    });
  },
};