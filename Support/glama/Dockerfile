# Glama's listing check: start the server and answer MCP introspection.
# Griasa's real MCP server runs inside the macOS app; this image runs only the
# Claude Desktop extension's stdio bridge from the latest release. Without the
# app it answers initialize and tools/list from the tool list captured at build
# time, and every tool call says Griasa is not running.
FROM node:22-alpine
RUN apk add --no-cache unzip
ADD https://github.com/Stari-am/griasa/releases/latest/download/Griasa.mcpb /tmp/griasa.mcpb
RUN unzip -q /tmp/griasa.mcpb -d /app && rm /tmp/griasa.mcpb
ENV GRIASA_STORE=/tmp/griasa
CMD ["node", "/app/server/index.js"]
