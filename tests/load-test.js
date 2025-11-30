#!/usr/bin/env node

/**
 * Load testing script for the log ingestion system
 * Generates ~1000 requests/minute with configurable concurrency
 */

const https = require('https');
const http = require('http');
const { URL } = require('url');

// Configuration
const CONFIG = {
  endpoint: process.env.API_ENDPOINT || 'https://your-api-gateway-url.amazonaws.com',
  requestsPerMinute: parseInt(process.env.RPM) || 1000,
  durationMinutes: parseInt(process.env.DURATION) || 1,
  tenants: ['acme_corp', 'beta_inc', 'gamma_ltd', 'delta_co', 'epsilon_org'],
};

// Stats
const stats = {
  total: 0,
  success: 0,
  errors: 0,
  latencies: [],
  errorTypes: {},
};

// Generate random log text of varying lengths
function generateLogText() {
  const templates = [
    'User login failed from IP 192.168.1.100',
    'Database query executed in 45ms for table users',
    'API request to /api/v1/orders completed with status 200',
    'Cache miss for key session:abc123, fetching from database',
    'Payment processed successfully for order #12345, amount $99.99',
    'Error: Connection timeout after 30s to service payment-gateway',
    'Scheduled job cleanup-old-logs started at 03:00 UTC',
    'WebSocket connection established from client 10.0.0.50',
  ];

  const template = templates[Math.floor(Math.random() * templates.length)];
  const timestamp = new Date().toISOString();
  const requestId = Math.random().toString(36).substring(7);

  return `[${timestamp}] [${requestId}] ${template}`;
}

// Make a single request (randomly JSON or text/plain)
async function makeRequest() {
  const isJson = Math.random() > 0.5;
  const tenant = CONFIG.tenants[Math.floor(Math.random() * CONFIG.tenants.length)];
  const logText = generateLogText();
  const logId = Math.random().toString(36).substring(2, 15);

  const url = new URL('/ingest', CONFIG.endpoint);
  const isHttps = url.protocol === 'https:';
  const client = isHttps ? https : http;

  let body, headers;

  if (isJson) {
    body = JSON.stringify({
      tenant_id: tenant,
      log_id: logId,
      text: logText,
    });
    headers = {
      'Content-Type': 'application/json',
    };
  } else {
    body = logText;
    headers = {
      'Content-Type': 'text/plain',
      'X-Tenant-ID': tenant,
    };
  }

  const startTime = Date.now();

  return new Promise((resolve) => {
    const req = client.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: 'POST',
        headers,
      },
      (res) => {
        const latency = Date.now() - startTime;

        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          stats.total++;
          stats.latencies.push(latency);

          if (res.statusCode >= 200 && res.statusCode < 300) {
            stats.success++;
          } else {
            stats.errors++;
            const errorType = `HTTP_${res.statusCode}`;
            stats.errorTypes[errorType] = (stats.errorTypes[errorType] || 0) + 1;
          }

          resolve({ success: res.statusCode < 300, latency, status: res.statusCode });
        });
      }
    );

    req.on('error', (err) => {
      const latency = Date.now() - startTime;
      stats.total++;
      stats.errors++;
      stats.latencies.push(latency);

      const errorType = err.code || 'UNKNOWN_ERROR';
      stats.errorTypes[errorType] = (stats.errorTypes[errorType] || 0) + 1;

      resolve({ success: false, latency, error: err.message });
    });

    req.write(body);
    req.end();
  });
}

// Calculate percentile
function percentile(arr, p) {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const index = Math.ceil((sorted.length * p) / 100) - 1;
  return sorted[index];
}

// Print stats
function printStats() {
  const successRate = ((stats.success / stats.total) * 100).toFixed(2);
  const errorRate = ((stats.errors / stats.total) * 100).toFixed(2);

  console.log('\n' + '='.repeat(60));
  console.log('LOAD TEST STATISTICS');
  console.log('='.repeat(60));
  console.log(`Total Requests:    ${stats.total}`);
  console.log(`Successful:        ${stats.success} (${successRate}%)`);
  console.log(`Failed:            ${stats.errors} (${errorRate}%)`);
  console.log('');
  console.log('Latency (ms):');
  console.log(`  Min:             ${Math.min(...stats.latencies)}`);
  console.log(`  Max:             ${Math.max(...stats.latencies)}`);
  console.log(`  P50:             ${percentile(stats.latencies, 50)}`);
  console.log(`  P95:             ${percentile(stats.latencies, 95)}`);
  console.log(`  P99:             ${percentile(stats.latencies, 99)}`);
  console.log(`  Avg:             ${(stats.latencies.reduce((a, b) => a + b, 0) / stats.latencies.length).toFixed(2)}`);

  if (Object.keys(stats.errorTypes).length > 0) {
    console.log('');
    console.log('Error Breakdown:');
    Object.entries(stats.errorTypes).forEach(([type, count]) => {
      console.log(`  ${type}: ${count}`);
    });
  }
  console.log('='.repeat(60) + '\n');
}

// Warmup phase to prime Lambda containers
async function warmup() {
  console.log('Warming up Lambda containers...');
  const warmupRequests = 10;
  const promises = [];

  for (let i = 0; i < warmupRequests; i++) {
    promises.push(makeRequest());
    await new Promise(resolve => setTimeout(resolve, 100)); // Stagger by 100ms
  }

  await Promise.all(promises);
  console.log(`Warmup complete (${warmupRequests} requests)\n`);
}

// Run load test
async function runLoadTest() {
  // Warmup first
  await warmup();

  // Wait for workers to finish processing warmup messages
  // (10 messages * ~5s each = 50s, but workers run concurrently)
  console.log('Waiting 15 seconds for workers to finish processing warmup messages...');
  await new Promise(resolve => setTimeout(resolve, 15000));

  console.log('Starting load test...');
  console.log(`Endpoint:          ${CONFIG.endpoint}`);
  console.log(`Duration:          ${CONFIG.durationMinutes} minute(s)`);
  console.log(`Test Concurrency:  ${process.env.TEST_CONCURRENCY || 2}`);
  console.log(`Mode:              Max throughput (fire as fast as possible)`);
  console.log(`Tenants:           ${CONFIG.tenants.join(', ')}`);
  console.log('');

  const concurrency = parseInt(process.env.TEST_CONCURRENCY) || 2;
  const durationMs = CONFIG.durationMinutes * 60 * 1000;

  // Reset stats after warmup
  stats.total = 0;
  stats.success = 0;
  stats.errors = 0;
  stats.latencies = [];
  stats.errorTypes = {};

  let requestsLaunched = 0;
  let activeRequests = 0;
  let testEnded = false;

  const startTime = Date.now();

  // Function to launch a request when slot is available
  const launchRequest = () => {
    if (testEnded) return;

    requestsLaunched++;
    activeRequests++;

    makeRequest()
      .then((result) => {
        activeRequests--;
        if (result.success) {
          process.stdout.write('.');
        } else {
          process.stdout.write('X');
        }
        // Immediately launch another if we have capacity and time remaining
        if (!testEnded && activeRequests < concurrency) {
          setImmediate(launchRequest);
        }
      })
      .catch(() => {
        activeRequests--;
        process.stdout.write('X');
        // Immediately launch another if we have capacity and time remaining
        if (!testEnded && activeRequests < concurrency) {
          setImmediate(launchRequest);
        }
      });
  };

  // Start initial batch up to concurrency limit
  for (let i = 0; i < concurrency; i++) {
    launchRequest();
  }

  // End test after duration
  await new Promise((resolve) => {
    setTimeout(() => {
      testEnded = true;
      console.log('\n\nTest duration reached. Waiting for in-flight requests to complete...');
      
      // Wait for all active requests to finish
      const checkComplete = setInterval(() => {
        if (activeRequests === 0) {
          clearInterval(checkComplete);
          resolve();
        }
      }, 100);
    }, durationMs);
  });

  const actualDuration = (Date.now() - startTime) / 1000;
  const throughputPerSecond = stats.total / actualDuration;
  const throughputPerMinute = throughputPerSecond * 60;

  console.log('');
  console.log('============================================================');
  console.log('MAX THROUGHPUT TEST RESULTS');
  console.log('============================================================');
  console.log(`Actual Duration:   ${actualDuration.toFixed(2)}s`);
  console.log(`Throughput:        ${throughputPerSecond.toFixed(2)} req/s (${throughputPerMinute.toFixed(0)} req/min)`);
  console.log('');

  printStats();
}

// Handle graceful shutdown
process.on('SIGINT', () => {
  console.log('\n\nInterrupted. Final stats:');
  printStats();
  process.exit(0);
});

// Run
runLoadTest().catch((err) => {
  console.error('Load test failed:', err);
  process.exit(1);
});
