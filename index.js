const texts = new Map([
  ["", `Hello world!`],
])

export default {
  async fetch(request, env, ctx) {
    // Method check, only GET and HEAD is allowed.
    if (request.method !== "GET" && request.method !== "HEAD")
      return new Response("405", { status: 405 })

    // Get rid of trailing slash
    let loc = new URL(request.url).pathname.replace("/", "")

    // robots.txt
    if (loc == "robots.txt")
      return new Response(`User-agent: *\nDisallow: /`)
    // Hello world
    if (texts.has(loc))
      return new Response(texts.get(loc), { status: 404 })

    // Only accept userstorage links
    if (loc.includes("userstorage.mega.co.nz")) {
      // Allow range header for partial downloads
      let newHeaders = new Headers
      if (request.headers.get("range"))
        newHeaders.append("range", request.headers.get("range"))

      // Fetch with headers
      let init = { headers: newHeaders }
      let response = await fetch(loc, init)
      return response
    } else {
      return new Response("403", { status: 403 })
    }
  }
}
