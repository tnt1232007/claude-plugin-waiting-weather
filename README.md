# Waiting Weather

A Claude Code plugin for Windows that makes it obvious when Claude is waiting on you. If Claude has been blocked for 10 seconds, rain or snow starts falling across every screen, and the project's VS Code taskbar button flashes. The weather stops as soon as you unblock Claude, or when you press Space. A note in the top-right corner says so, and counts down to the remote alert.

Claude counts as blocked while one of these is open:

- A question (`AskUserQuestion`) or a plan approval (`ExitPlanMode`)
- A permission prompt
- An MCP server or a subagent asking for input

By default, questions bring snow and permission prompts bring rain.

## Install

In a Claude Code terminal session, run:

```
/plugin install waiting-weather --marketplace tnt1232007/claude-plugin-waiting-weather
```

Answer `y` to add the marketplace, then pick a scope. The user scope makes it work in every project.

## Stopping the weather

The weather fades out when any of these happens:

- You answer the question or the permission prompt
- You send a new message, or the turn ends
- You press Space. This also cancels the remote alert for everything Claude is waiting on at that moment
- `max_seconds` pass

The overlay is click-through and never takes focus, so you can keep working while it falls.

Space is read from the keyboard in whichever window has focus, and that press is swallowed: it never reaches the focused window, so it cannot pick or submit an answer in Claude's dialog. Esc is left alone, since in Claude Code it interrupts the current turn.

## Settings

Open `/config` to change these options:

| Option | Default | What it does |
| --- | --- | --- |
| `delay_seconds` | `10` | How long Claude must wait on you before the weather starts |
| `question_effect` | `snow` | `snow` or `rain` for a question, plan approval or input dialog |
| `question_color` | `#FFFFFF` | Hex color of the question effect |
| `permission_effect` | `rain` | `snow` or `rain` for a permission prompt |
| `permission_color` | `#60A5FA` | Hex color of the permission effect |
| `max_seconds` | `120` | The longest the weather runs. Keep it above `remote_delay_seconds` to see the countdown reach the remote alert |
| `remote_url` | empty | Apprise API notify endpoint for remote alerts. Empty turns them off |
| `remote_tag` | empty | Apprise tag the remote alert is sent with |
| `remote_delay_seconds` | `60` | How long Claude must wait on you before the remote alert goes out |

## Remote alerts

The weather only helps when you are at the screen. To get alerts while you are away, point `remote_url` at an [Apprise API](https://github.com/caronc/apprise-api) `/notify/<key>` endpoint. Apprise then forwards the alert to Telegram, ntfy, Discord or any other service it supports.

If Claude is still blocked after `remote_delay_seconds`, the plugin posts one alert with enough detail to decide your answer:

- A question: every question with its numbered options
- A plan approval: the plan
- A permission prompt: the tool and its command, file, URL or pattern
- An input dialog: its message

The remote alert works on any OS. You still answer in Claude Code itself.

## Requirements

- Windows 10 or 11, with Windows PowerShell 5.1, which ships with Windows
- VS Code, for the taskbar flash. The weather itself works with any editor or terminal

The effect does nothing on macOS or Linux. Remote alerts still work there.

## How it works

The plugin is a Claude Code mod: a hooks module (`hooks/register.ts`) that tracks each blocking call by its own id, so parallel tool calls never clear each other. When a block passes the delay, it runs `scripts/alert.ps1`, which draws the weather on a per-pixel-alpha overlay window with GDI+.

While it runs, rain uses about 40% of one CPU core and snow about 10%.

The look follows [RainProject](https://github.com/riyasy/RainProject): thin rain streaks that splatter into bouncing droplets, and soft snowflakes that settle into a heap. This plugin is a separate implementation, not a port of RainProject's source.

The mod API is in early access, so a Claude Code update may require changes to the plugin.

## License

MIT
