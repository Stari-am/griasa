# Search benchmark

48 queries a person might type to find a moment in the six invented meetings of
`benchmark/meetings/`, eight of each kind:

| Kind | Example |
|---|---|
| `paraphrase` | other words than the meeting used: "кто сообщит заказчику о сбое" |
| `cross` | another language than the meeting: an English query for a Ukrainian passage |
| `inflection` | dictionary forms where the meeting used other cases: "кандидат оффер" |
| `exact` | a name, product or number: "Onboarding v3" |
| `topic` | two or three words: "pricing tiers" |
| `question` | "who owns the migration?" |

`queries.json` holds each query with its `meeting` and an `anchor`: words copied
exactly from that meeting's transcript, from the passage that answers it.
Meetings are cut into pieces of about 800 characters (`SearchChunks`); the
answer is the piece that holds the anchor.

Run from the repo root:

```
Griasa --search-benchmark benchmark/meetings
```

It ranks the pieces with the old one-phrase match and with word search
(`WordSearch`). With `--embed-url` naming an OpenAI-style embeddings endpoint
it also ranks them by the model alone and fused with word search (`HybridRank`):

```
llama-server -m bge-m3-q8_0.gguf --embedding --pooling cls --host 127.0.0.1 --port 8091 -c 8192 -b 8192 -ub 8192
Griasa --search-benchmark benchmark/meetings --embed-url http://127.0.0.1:8091
```

`--query-prefix` and `--passage-prefix` add the prefixes some models expect
(`"query: "` and `"passage: "` for the e5 family). It prints recall@5 (the
answer is among the first five pieces) and MRR (1 / its position in the first
ten), overall and per kind, and writes `dist/search-benchmark-<date>/RESULTS.md`.

With [bge-m3](https://huggingface.co/ggml-org/bge-m3-Q8_0-GGUF) (Q8_0):

| Search | R@5 | MRR |
|---|---:|---:|
| one phrase (before 1.0.23) | 0.17 | 0.12 |
| word search | 0.60 | 0.47 |
| bge-m3 | 0.77 | 0.60 |
| bge-m3 + word search | 0.81 | 0.64 |

Eight queries per kind means one query moves a kind's number by 0.125: read the
per-kind columns as a direction, not a measurement.
