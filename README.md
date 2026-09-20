# ioping Prometheus Exporter

A simple, lightweight Prometheus textfile collector for monitoring disk and storage I/O latency. 

It runs continuous pings with `ioping` and maintains a Prometheus-compatible histogram, exporting the metrics atomically so they can be scraped by `node_exporter` via the textfile collector module.

Note: Google Gemini (AI) did most of the heavy lifting on this, I'm also using this as a hobby project to explore agenic workflows. 

## Why use this?

When tracking I/O performance, response times typically follow a long-tailed distribution (e.g., log-normal or Pareto). Storage arrays usually return data extremely fast (microseconds) if it hits NVMe caching, but if it has to seek a spinning disk or hits a network block on an NFS share, latency can spike to milliseconds or even seconds.

This script tracks these latencies using a **high-resolution histogram** optimized for network-attached storage (like Ceph RBD and NFS):
`0.00025, 0.0005, 0.00075, 0.001, 0.0015, 0.002, 0.003, 0.004, 0.005, 0.0075, 0.01, 0.015, 0.02, 0.03, 0.04, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 2, 5, 10, 30, 60, +Inf`

This scale provides extreme resolution in the crucial `1ms` to `100ms` window where network storage performance typically fluctuates (e.g. Ethernet switch queuing, synchronous replication delays in Ceph), while still safely bucketing extreme stalls (up to 60 seconds) characteristic of NFS timeouts.

## How it Works

1. **Continuous Output:** It runs `ioping` indefinitely, piping its line-by-line output directly into a background `awk` process. 
2. **Cumulative State:** The `awk` process stays alive and holds the cumulative histogram counters in memory. This adheres to Prometheus standards, which expect histogram counters to be monotonically increasing until the exporter is restarted.
3. **Atomic File Writes:** Every `WRITE_EVERY` iterations, it flushes the counters to a temporary `.tmp` file and then `mv`s it over the actual `.prom` file. In Linux, `mv` across the same filesystem is an atomic operation, meaning the Prometheus textfile collector will never accidentally scrape a partially written file.

## Requirements

- `bash`
- `awk` (standard POSIX awk works perfectly, no `gawk` required)
- `ioping`

All other tools are standard GNU/Linux coreutils.

## Installation & Usage

1. Copy the exporter script to `/usr/local/bin` and make it executable:

```bash
chmod +x ioping-exporter.sh
sudo cp ioping-exporter.sh /usr/local/bin/
```

2. Test it locally:

```bash
# Run against the current directory, updating the metrics file every 10 pings
INTERVAL=1 WRITE_EVERY=10 PROM_FILE=./ioping.prom ./ioping-exporter.sh .
```

### Environment Variables

You can customize the exporter behavior using the following environment variables:

- `TARGET_DIR` (or passed as argument 1): The directory to test I/O against (default: `.`)
- `PROM_FILE`: The output `.prom` file path (default: `ioping.prom`)
- `INTERVAL`: Delay between `ioping` requests in seconds (default: `1`)
- `WRITE_EVERY`: How many pings to wait before flushing to the `.prom` file (default: `10`)
- `IOPING_BIN`: Path to the `ioping` binary (default: `ioping`)


Here are some example Prometheus alerting rules you can add to your configuration to catch storage degradation:

```yaml
groups:
- name: ioping_alerts
  rules:
  - alert: HighIOLatency
    expr: histogram_quantile(0.95, rate(ioping_latency_seconds_bucket[$__rate_interval])) > 0.05
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "High I/O latency on {{ $labels.instance }}"
      description: "95th percentile I/O latency is greater than 50ms for more than 2 minutes. (Current value: {{ $value }}s)"

  - alert: CriticalIOLatency
    expr: histogram_quantile(0.99, rate(ioping_latency_seconds_bucket[$__rate_interval])) > 0.5
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "Critical I/O latency on {{ $labels.instance }}"
      description: "99th percentile I/O latency is greater than 500ms for more than 2 minutes. This indicates severely blocked I/O. (Current value: {{ $value }}s)"
```


## Running as a systemd service

To run this continuously as a background daemon, you can use either the non-instanced or instanced systemd unit files.

### Non-instanced (single target)

1. Create a dedicated directory for textfile metrics if you don't have one:
```bash
sudo mkdir -p /var/lib/prometheus/node-exporter
```

2. Copy the unit file:
```bash
sudo cp ioping-exporter.service /etc/systemd/system/
```

3. Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ioping-exporter.service
sudo systemctl status ioping-exporter.service
```

### Instanced version (multiple targets, e.g. different mount points)

The `ioping-exporter@.service` template lets you run separate instances for different directories.

**Important:** Use `systemd-escape` to safely encode paths as instance names.

Example for `/mnt/my-mount`:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now "ioping-exporter@$(systemd-escape /mnt/my-mount).service"
sudo systemctl status "ioping-exporter@$(systemd-escape /mnt/my-mount)"
```

You can also check logs with:
```bash
journalctl -u "ioping-exporter@$(systemd-escape /mnt/my-mount)"
```

The instanced unit automatically uses `%I` for the path and `%i` for unique `.prom` filenames so multiple instances don't conflict.

## Alertmanager Examples

Here are some example Prometheus alerting rules you can add to your configuration to catch storage degradation:

```yaml
groups:
- name: ioping_alerts
  rules:
  - alert: HighIOLatency
    expr: histogram_quantile(0.95, rate(ioping_latency_seconds_bucket[$__rate_interval])) > 0.05
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "High I/O latency on {{ $labels.instance }}"
      description: "95th percentile I/O latency is greater than 50ms for more than 2 minutes. (Current value: {{ $value }}s)"

  - alert: CriticalIOLatency
    expr: histogram_quantile(0.99, rate(ioping_latency_seconds_bucket[$__rate_interval])) > 0.5
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "Critical I/O latency on {{ $labels.instance }}"
      description: "99th percentile I/O latency is greater than 500ms for more than 2 minutes. This indicates severely blocked I/O. (Current value: {{ $value }}s)"
```

## Grafana Dashboard Examples

Since the exporter generates a standard Prometheus histogram, you can use the `histogram_quantile` function or Grafana's Heatmap panel to visualize the data. Note that metrics now include an `operation` label (`read` or `write`).

### 95th Percentile Latency (Time Series)
To see the 95th percentile latency over time, split by read and write:
```promql
histogram_quantile(0.95, sum(rate(ioping_latency_seconds_bucket[$__rate_interval])) by (le, target, operation))
```

### Average Latency (Time Series)
To calculate the true average latency using the sum and count metrics:
```promql
rate(ioping_latency_seconds_sum[$__rate_interval]) / rate(ioping_latency_seconds_count[$__rate_interval])
```

### Latency Heatmap (Heatmap Panel)
Histograms are best visualized as heatmaps. In Grafana, select the **Heatmap** visualization type. To view read latency:
```promql
sum(rate(ioping_latency_seconds_bucket{operation="read"}[$__rate_interval])) by (le)
```
*Note: In the Grafana Heatmap settings, make sure to set "Format" to "Heatmap" in the query options, and set Data Format to "Time series buckets".*


### Max Latency / p100 (Time Series)
To see the absolute maximum observed latency (p100 / worst case):

```promql
histogram_quantile(1, sum(rate(ioping_latency_seconds_bucket[$__rate_interval])) by (le, target, operation))
```
