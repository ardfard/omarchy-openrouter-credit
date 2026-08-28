# OpenRouter Credit

An Omarchy bar widget that shows your OpenRouter credit in the bar, and ranks
OpenRouter's model catalogue by **value** and by **price** in the detail panel.

```
bar:    OR $3.42
panel:  balance card + "Best value" + "Best cheap"
```

The bar pill is deliberately minimal — balance only. Everything else lives one
click away.

## Install

```bash
git clone https://github.com/ardfard/omarchy-openrouter-credit
cd omarchy-openrouter-credit
./install.sh
```

`install.sh` copies the plugin to `~/.config/omarchy/plugins/io.github.ardfard.openrouter-credit`,
runs `omarchy plugin validate`, rescans the plugin registry, and offers to add
the widget to the right-hand bar section.

## Remove

```bash
omarchy plugin disable io.github.ardfard.openrouter-credit
omarchy plugin remove io.github.ardfard.openrouter-credit
# or, if `plugin remove` is unavailable on your Omarchy version:
rm -rf ~/.config/omarchy/plugins/io.github.ardfard.openrouter-credit
omarchy shell shell rescanPlugins
```

Requires `curl` (fetching) and `wl-copy` (copy-model-id); both ship with Omarchy.

## API key

The balance comes from `GET https://openrouter.ai/api/v1/auth/key`, which needs
a key. Two ways to provide one, checked in this order:

1. the `apiKey` setting in `shell.json` — paste it into the panel's masked
   **API key** field and hit **Save**
2. `OPENROUTER_API_KEY` in the shell's environment

The environment route is the better one if you already export the key for the
OpenRouter CLI or an editor plugin: nothing lands in `shell.json`, and the panel
shows `(from $OPENROUTER_API_KEY)` so you know which source is live. Either way
the key is passed to `curl` through the process *environment*, never argv, so it
does not show up in `ps`.

Get a key at <https://openrouter.ai/settings/keys>.

**The rankings need no key** — `/api/v1/models` is public, so the panel is a
usable price table before you configure anything.

## Bar states

| Pill | Meaning |
| --- | --- |
| `OR $3.42` | `limit_remaining` from `/auth/key` |
| `OR $1.20 used` | key has no spend limit, so there is no "remaining" — shows `usage` |
| `OR ◷` | first fetch in flight |
| `OR —` | no API key configured |
| `OR !` | request failed; the panel shows OpenRouter's own error text |

A `FREE TIER` badge appears on the balance card when `is_free_tier` is true.

Mouse: left-click toggles the panel, right-click refreshes, middle-click opens
<https://openrouter.ai/settings/credits>.

## Ranking method

Both lists are derived from the public `/api/v1/models` catalogue. Prices there
are USD per token; the panel shows them per 1M tokens.

```
blended = (prompt + completion) / 2          # $ per 1M tokens
value   = log₁₀(context_length) / blended    # context per dollar
```

**Best value** — top N by `value`, descending. `log₁₀` is deliberate: context
has sharply diminishing returns, so a 1M-token window scores roughly 20% better
than a 128K one rather than 8× better. Limited to priced models with at least
32K context; free models would divide by zero and are covered by the other list.

**Best cheap** — ascending `blended`, ties broken by larger context.
Tool-calling models come first; if fewer than N support tools the list is topped
up with the cheapest remaining ones rather than returned short.

Both lists exclude meta-routers (`openrouter/auto`, which prices at `-1`),
non-text-output models, and models whose `expiration_date` has passed.

This is a **price heuristic, not a benchmark**. OpenRouter publishes no quality
metric on `/models`, so context length stands in as a rough capability proxy.
The panel says as much in each section subtitle.

Click any row to copy the full model id to the clipboard.

## Settings

Stored in `~/.config/omarchy/shell.json` under this widget's entry. The panel
edits all of them; you can also write them by hand.

| Key | Type | Default | Range |
| --- | --- | --- | --- |
| `apiKey` | string | `""` | falls back to `$OPENROUTER_API_KEY` |
| `refreshMinutes` | int | `5` | 1–60 |
| `valueCount` | int | `8` | 4–16 |
| `cheapCount` | int | `8` | 4–16 |

```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "io.github.ardfard.openrouter-credit", "refreshMinutes": 5, "valueCount": 8, "cheapCount": 8 }
      ]
    }
  }
}
```

## Refresh behaviour

The balance is polled every `refreshMinutes` (floor of 1 minute) and retried
30 s after a failure. The model catalogue moves on a scale of days, so it is
fetched when the panel opens and then cached for 6 hours. The panel's **Refresh**
button forces both.

## IPC

```bash
omarchy-shell ipc call io.github.ardfard.openrouter-credit refresh
omarchy-shell ipc call io.github.ardfard.openrouter-credit toggle
omarchy-shell ipc call io.github.ardfard.openrouter-credit open
omarchy-shell ipc call io.github.ardfard.openrouter-credit close
```

## Testing the model

`Model.js` is plain JavaScript with no QML dependencies, so the parsing and
ranking can be exercised straight from node:

```bash
curl -s https://openrouter.ai/api/v1/models > /tmp/models.json
node -e '
  const M = require("./Model.js");
  const models = M.parseModelsResponse(require("fs").readFileSync("/tmp/models.json","utf8"));
  M.rankByValue(models, 8).forEach((m,i) =>
    console.log(`${i+1}. ${m.id}  ${M.priceHint(m)}  ${M.formatContext(m.contextLength)} ctx`));
'
```

Lint the QML the way `install.sh` does:

```bash
qmllint -I /usr/share/omarchy/shell BarWidget.qml Panel.qml
```

## Relationship to `io.github.spoilheap.openrouter`

That plugin shows the balance. This one keeps the same minimal pill and adds the
value/price ranking behind it. They can coexist; you probably want one or the
other in the bar.

## License

MIT — see [LICENSE](LICENSE).
