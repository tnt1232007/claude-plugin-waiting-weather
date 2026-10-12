# Waiting Weather

A Claude Code plugin for Windows that makes it obvious when Claude is waiting on you. If Claude has been blocked for 10 seconds, rain or snow starts falling across every screen, and the project's VS Code taskbar button flashes. The weather stops as soon as you unblock Claude, or when you press Esc.

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
- You press Esc
- `max_seconds` pass

The overlay is click-through and never takes focus, so you can keep working while it falls.

Esc is read from the keyboard in whichever window has focus. If the question or permission dialog has focus, the same Esc may also dismiss it.

## Settings

Open `/config` to change these options:

| Option | Default | What it does |
| --- | --- | --- |
| `delay_seconds` | `10` | How long Claude must wait on you before the weather starts |
| `question_effect` | `snow` | `snow` or `rain` for a question, plan approval or input dialog |
| `question_color` | `#FFFFFF` | Hex color of the question effect |
| `permission_effect` | `rain` | `snow` or `rain` for a permission prompt |
| `permission_color` | `#60A5FA` | Hex color of the permission effect |
| `max_seconds` | `120` | The longest the weather runs |

## Requirements

- Windows 10 or 11, with Windows PowerShell 5.1, which ships with Windows
- VS Code, for the taskbar flash. The weather itself works with any editor or terminal

The effect does nothing on macOS or Linux.

## How it works

The plugin is a Claude Code mod: a hooks module (`hooks/register.ts`) that tracks each blocking call by its own id, so parallel tool calls never clear each other. When a block passes the delay, it runs `scripts/alert.ps1`, which draws the weather on a per-pixel-alpha overlay window with GDI+.

While it runs, rain uses about 40% of one CPU core and snow about 10%.

The look follows [RainProject](https://github.com/riyasy/RainProject): thin rain streaks that splatter into bouncing droplets, and soft snowflakes that settle into a heap. This plugin is a separate implementation, not a port of RainProject's source.

The mod API is in early access, so a Claude Code update may require changes to the plugin.

## License

MIT
