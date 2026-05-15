# Signal Subscriptions — [Project Name]

Configuration for the @signal agent. Defines what to monitor and where to look.

## Project Topics

<!-- Topics relevant to this specific project. The signal agent scans for these. -->

### Topic: [topic-name]
- **keywords**: [keyword1, keyword2, keyword3]
- **sources**: [github, hackernews, arxiv, rss, x, producthunt, blogs]
- **priority**: high | medium | low
- **scan_mode**: quick | deep

## RSS Feeds

<!-- Direct feed URLs to check on every scan -->
<!-- Full OPML list: https://gist.github.com/emschwartz/e6d2bf860ccc367fe37ff953ba6de66b -->

### Curated Tech Blogs (from HN top 100)

| Feed Name | URL | Topics |
|-----------|-----|--------|
| Simon Willison | https://simonwillison.net/atom/everything/ | AI, LLMs, tools |
| antirez | http://antirez.com/rss | systems, Redis, programming |
| Mitchell Hashimoto | https://mitchellh.com/feed.xml | systems, infrastructure, Zig |
| matklad | https://matklad.github.io/feed.xml | compilers, Rust, IDE |
| Xe Iaso | https://xeiaso.net/blog.rss | infrastructure, NixOS, AI |
| overreacted (Dan Abramov) | https://overreacted.io/rss.xml | React, frontend, design |
| rachelbythebay | https://rachelbythebay.com/w/atom.xml | systems, debugging, war stories |
| Eli Bendersky | https://eli.thegreenplace.net/feeds/all.atom.xml | compilers, Go, programming |
| gwern | https://gwern.net/feed.xml | AI, research, statistics |
| Troy Hunt | https://www.troyhunt.com/rss/ | security, breaches, HIBP |
| Fabien Sanglard | https://fabiensanglard.net/rss.xml | graphics, systems, game engines |
| Paul Graham | http://www.aaronsw.com/2002/feeds/pgessays.rss | startups, essays |
| Krebs on Security | https://krebsonsecurity.com/feed/ | security, cybercrime |
| Pluralistic (Cory Doctorow) | https://pluralistic.net/feed/ | tech policy, digital rights |
| Hillel Wayne | https://buttondown.com/hillelwayne/rss | formal methods, testing, CS |

### Research & AI Feeds

| Feed Name | URL | Topics |
|-----------|-----|--------|
| Anthropic Blog | https://www.anthropic.com/blog/rss.xml | claude, AI safety, research |
| ArXiv cs.AI | http://export.arxiv.org/rss/cs.AI | AI research papers |
| ArXiv cs.MA | http://export.arxiv.org/rss/cs.MA | multi-agent systems papers |
| ArXiv cs.CL | http://export.arxiv.org/rss/cs.CL | NLP, language models papers |
| HN Best | https://hnrss.org/best | top HN stories |

### Project-Specific Feeds

| Feed Name | URL | Topics |
|-----------|-----|--------|
| Example Blog | https://example.com/feed.xml | [topic] |

## Reddit Subreddits

<!-- Subreddits to monitor via RSS (https://www.reddit.com/r/{sub}/.rss) -->

| Subreddit | Topics |
|-----------|--------|
| r/ClaudeAI | claude, plugins, agent-patterns |
| r/LocalLLaMA | models, inference, fine-tuning |
| r/MachineLearning | research, papers, trends |

## GitHub Watches

<!-- Repos to monitor for new releases, issues, or activity -->

| Repo | Watch For | Topics |
|------|-----------|--------|
| anthropics/claude-code | releases, issues | claude-code, plugins |

## Key Accounts (Social)

<!-- Accounts to monitor on social platforms -->

| Platform | Account | Topics |
|----------|---------|--------|
| X | @AnthropicAI | announcements, releases |

## Scan Schedule

- **Quick scan**: Every session start (Tier 1 sources only)
- **Deep scan**: Weekly or on `/team-signal deep`
- **Targeted scan**: On-demand by coordinator

## Role Interest Overrides

<!-- Override or extend default role subscriptions for this project -->
<!-- Format: role: [additional-topics] -->

<!--
developer: [framework-updates, dependency-vulnerabilities]
security: [cve-disclosures, supply-chain-attacks]
architect: [design-patterns, scaling-approaches]
-->
