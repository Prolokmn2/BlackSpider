# BlackSpider

A tracing sandbox + deobfuscator for Lua / Luau scripts (Roblox executor scripts in particular).
It never runs the target with the host's compiler: it parses the script with its own parser
(no nesting limit) and executes it step by step in a fake executor, so it can watch everything.

* **Code guesser** – rebuilds readable source: constant folding, runtime-decoded strings, literal
  inlining, dead-branch removal, readable names, plus a reconstruction of what the script *did*.
* **Net guard** – every http/websocket vector is hooked. Requests are recorded and blocked.
* **Spider mode** – follows `loadstring(game:HttpGet(url))()` chains and analyses every script it finds.
* **Emulator mode** – fires the callbacks a script registers (`:Connect`, `.OnClientEvent = f` ...).

## Use (executor)

```lua
getgenv().BlackSpiderConfig = {
    TARGET_URL = "https://example.com/script.lua",   -- or TARGET_CODE = 'loadstring(game:HttpGet("..."))()'
    SPIDER     = true,                               -- optional crawl mode
}
loadstring(game:HttpGet("https://raw.githubusercontent.com/prolokmn2/BlackSpider/main/loader.lua"))()
```

Input priority: `TARGET_CODE` (raw code or a loadstring line) > `TARGET_URL` (downloaded with the
executor's `request`, raw copy saved to `output.txt`) > `TARGET_FILE` (file in the workspace).
Every option lives in [`src/config.lua`](src/config.lua).

Run from a local copy instead of GitHub: put the repo in `workspace/BlackSpider/` (`SOURCE = "auto"`
prefers it), or `SOURCE = "local"` / `"github"` to force one.

Desktop Lua (5.1–5.4 / LuaJIT): `texlua tests/run.lua yourfile.lua` (or `lua`). Downloading needs an
executor, so URL input and spider mode only work inside one.

## Output (`BlackSpider_out/`)

| file | content |
|---|---|
| `p0_report.txt` | verdict, net guard, webhooks/urls, requests, keys, full step log |
| `p0_guessed_code.lua` | cleaned main chunk + every loadstring layer + reconstructed behaviour + decoded strings |
| `p0_guessed_output.txt` | what it would print / send / write |
| `p0_recovered.txt` | every recovered string / variable |
| `p0_layer_N.lua`, `p0_raw.lua` | raw layers, raw input |
| `p1_*`, `p2_*` ... | the same for every page the spider found |
| `index.txt` | crawl tree |

## Spider mode

When the analysed script does a **GET** (`game:HttpGet`, `request{Method="GET"}`), the spider downloads that
url with your executor's `request`, hands the real content back to the script (so the chain keeps running)
and, with `SPIDER = true`, analyses the downloaded script on its own (`pN_` files).

Guard rails: GET only · http(s) only · no headers/body from the analysed script are forwarded · loopback,
private, link-local and obfuscated-IP hosts refused · discord and known IP-logger domains refused (`SPIDER_DENY`)
· optional `SPIDER_ALLOW` list · `SPIDER_MAX_PAGES` / `SPIDER_MAX_BYTES` / `SPIDER_MAX_DEPTH`.
With `SPIDER = false`, `FOLLOW_LOADER` still follows exactly one GET so a pasted loader line works.

**Heads up:** crawling contacts the script author's servers from *your* IP. Use a VPN / throwaway
network if that matters. `SPIDER_MAX_DEPTH` counts separate analysis hops; scripts loaded inside one
run are bounded by `SPIDER_MAX_PAGES`.

## The code guesser

1. **Static pass** (`G.clean`): `string.char(72,105)`, `"a".."b"`, `bit32.bxor(1,2)`, `("x"):reverse()`,
   `table.concat({...})`, `if 1==2`, `a["b"]` -> `a.b`, `local a = "lit"` inlined, `IIlIlI`/`_0x3f` renamed
   from how they are used (`game:GetService("Players")` -> `Players`, `Instance.new("Frame")` -> `frame`).
2. **Dynamic folding**: calls with constant arguments to the script's own decoder functions and constant-array
   lookups (`T[41]`) are replaced by the value the sandbox actually saw them return.
3. **Trace** (`G.trace`): the runtime behaviour as code with aliases and event grouping. This is the one that
   still works on VM-style obfuscators, where the AST is only an interpreter.

## Layout

```
loader.lua            entry point, loads src/* from GitHub or the local folder
src/util.lua          helpers, file io             src/guesser.lua   the deobfuscator
src/config.lua        defaults + overrides         src/report.lua    outputs
src/lexer.lua         Lua + Luau extras            src/spider.lua    crawl mode
src/parser.lua        AST (types/if-expr/interp)   src/fetcher.lua   executor GET (FileSaver logic)
src/state.lua         runtime state + recording    src/emulator.lua  callback emulator
src/netguard.lua      http hooks, tamper/escape    src/env.lua       fake executor + ghosts
src/compiler.lua      AST -> closures              src/main.lua      analyze / start
tests/                local runners + samples
```

## Limits

No `goto`. Bytecode layers are saved but not interpreted. A host-level bug in the Lua running the tool is
out of scope for the sandbox: analyse hostile scripts in a throwaway environment.

## Publish

```bash
cd BlackSpider
git init && git add . && git commit -m "BlackSpider"
git branch -M main
git remote add origin https://github.com/prolokmn2/BlackSpider.git
git push -u origin main
```
