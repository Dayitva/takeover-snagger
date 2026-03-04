FROM ubuntu:22.04

RUN apt-get update && apt-get install -y curl git jq && rm -rf /var/lib/apt/lists/*

RUN curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup

ENV PATH="/root/.foundry/bin:${PATH}"

WORKDIR /app
COPY script/monitor.sh script/monitor.sh
RUN chmod +x script/monitor.sh

CMD ["./script/monitor.sh"]
