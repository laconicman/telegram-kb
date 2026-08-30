# ``TelegramKB``

A searchable knowledge base built from Telegram channels, exposed to Claude over MCP.

## Overview

Useful articles, libraries and documentation get shared in Telegram channels and then become
unfindable. Telegram's own search cannot do substring matching, its query normalisation is
opaque, and it has no notion of "what did anyone share about X, ranked by what people actually
reacted to". This project turns that corpus into something you can ask questions of, with
citations back to the original `t.me` posts.

The shape of the system follows from one observation: **the corpus is historical, not live.**
An article shared last week is as useful as one shared today, so recall and ranking matter and
freshness barely does. That makes a local index the product and Telegram merely an ingestion
source.

Two executables over one SQLite store:

| | |
|---|---|
| `tgkb` | Ingestion. Crawls channels, writes the index. Owns all network and credentials. |
| `tgkb-mcp` | A read-only stdio MCP server. No network, no credentials, no ban exposure. |

## Topics

### Project Direction

These four documents outrank the README and any code comment.

- <doc:Design>
- <doc:Roadmap>
- <doc:TechDebt>
- <doc:Research>
