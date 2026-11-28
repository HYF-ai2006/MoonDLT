#!/usr/bin/env node
// File I/O adapter only. Protocol decoding and query evaluation run in MoonBit.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cli = path.join(root, '_build/js/debug/build/cmd/node/node.js');
const maxModelBytes = 8 * 1024 * 1024;

function usage() {
  throw new Error('Usage: node scripts/moondlt.mjs inspect INPUT [--filter EXPR] [--limit 100]\n       node scripts/moondlt.mjs extract INPUT OUTPUT [--filter EXPR]\n       node scripts/moondlt.mjs decode RECORD.dlt [MODEL.json]\n       node scripts/moondlt.mjs encode MODEL.json RECORD.dlt');
}

function options(args) {
  const [operation, input, ...rest] = args;
  if (operation === 'decode' || operation === 'encode') {
    if (!input || rest.length > 1 || (operation === 'encode' && rest.length !== 1)) usage();
    return { operation, input: path.resolve(input), output: rest[0] && path.resolve(rest[0]) };
  }
  if (!['inspect', 'extract'].includes(operation) || !input) usage();
  let output;
  if (operation === 'extract') {
    output = rest.shift();
    if (!output || output.startsWith('--')) usage();
  }
  const result = { operation, input: path.resolve(input), output: output && path.resolve(output), filter: '', limit: 100 };
  const seen = new Set();
  while (rest.length) {
    const key = rest.shift();
    if (!['--filter', '--limit'].includes(key) || seen.has(key) || rest.length === 0) usage();
    seen.add(key);
    const value = rest.shift();
    if (key === '--filter') result.filter = value;
    else {
      if (operation !== 'inspect' || !/^\d+$/.test(value) || Number(value) > 10000) usage();
      result.limit = Number(value);
    }
  }
  return result;
}

function build() {
  // Invoke Moon directly, with no shell interpolation of user-controlled paths.
  const command = process.platform === 'win32' ? 'moon.exe' : 'moon';
  const result = spawnSync(command, ['build', 'cmd/node', '--target', 'js', '--deny-warn'], { cwd: root, encoding: 'utf8' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`MoonBit build failed:\n${result.stderr || result.stdout}`);
}

async function main() {
  const settings = options(process.argv.slice(2));
  const samePath = settings.output && (process.platform === 'win32'
    ? settings.input.toLowerCase() === settings.output.toLowerCase()
    : settings.input === settings.output);
  if (samePath) {
    throw new Error('Input and output must be different files');
  }
  build();
  const library = await import(pathToFileURL(cli).href);
  let inputFd;
  let outputFd;
  let createdOutput = false;
  let completed = false;
  try {
    inputFd = fs.openSync(settings.input, 'r');
    const initial = fs.fstatSync(inputFd, { bigint: true });
    if (!initial.isFile()) throw new Error('Input must be a regular file');
    if (initial.size > 0xffffffffffffffffn) throw new Error('Input size exceeds UInt64');
    if (settings.operation === 'decode' || settings.operation === 'encode') {
      const decoding = settings.operation === 'decode';
      const budget = decoding ? 65551n : BigInt(maxModelBytes);
      if (initial.size > budget) throw new Error('Single-record input exceeds its size limit');
      const input = Buffer.alloc(Number(initial.size));
      let bytesRead = 0;
      while (bytesRead < input.length) {
        const count = fs.readSync(inputFd, input, bytesRead, input.length - bytesRead, bytesRead);
        if (!count) throw new Error('Short input read');
        bytesRead += count;
      }
      const current = fs.fstatSync(inputFd, { bigint: true });
      if (current.size !== initial.size || current.mtimeNs !== initial.mtimeNs) throw new Error('Input changed during read');
      const report = JSON.parse(decoding ? library.decode_record(input) :
        library.encode_record(new TextDecoder('utf-8', { fatal: true }).decode(input)));
      if (!report.success) throw new Error(report.error);
      let data = decoding ? JSON.stringify(report.message, null, 2) + '\n' : Buffer.from(report.hex, 'hex');
      if (decoding && Buffer.byteLength(data) > maxModelBytes) {
        // Indentation alone can take a legal, deeply nested record over the
        // encode command's JSON limit. Keep the output readable when it fits.
        data = JSON.stringify(report.message) + '\n';
      }
      if (settings.output) {
        outputFd = fs.openSync(settings.output, 'wx');
        createdOutput = true;
        fs.writeFileSync(outputFd, data);
        fs.fsyncSync(outputFd);
      } else process.stdout.write(data);
      completed = true;
      return;
    }
    if (settings.operation === 'extract') {
      // Exclusive creation: existing recordings are never overwritten.
      outputFd = fs.openSync(settings.output, 'wx');
      createdOutput = true;
    }
    let reads = 0;
    let largestRead = 0;
    const host = {
      read(offset, length) {
        const position = BigInt(offset);
        if (!Number.isInteger(length) || length < 0 || position < 0n || position + BigInt(length) > initial.size) {
          throw new Error('MoonBit requested an invalid source range');
        }
        const bytes = Buffer.alloc(length);
        let filled = 0;
        while (filled < length) {
          const count = fs.readSync(inputFd, bytes, filled, length - filled, position + BigInt(filled));
          if (count === 0) throw new Error('Input changed or returned a short read');
          filled += count;
        }
        reads += 1;
        largestRead = Math.max(largestRead, length);
        return bytes;
      },
      write(bytes) {
        if (outputFd === undefined) throw new Error('Output was not opened');
        let written = 0;
        while (written < bytes.length) {
          const count = fs.writeSync(outputFd, bytes, written, bytes.length - written);
          if (count === 0) throw new Error('Output returned a short write');
          written += count;
        }
        return written;
      },
    };
    const raw = settings.operation === 'inspect'
      ? library.inspect_file(host, initial.size.toString(), settings.filter, settings.limit)
      : library.extract_file(host, initial.size.toString(), settings.filter);
    const report = JSON.parse(raw);
    if (!report.success) throw new Error(report.error || 'MoonBit file operation failed');
    const final = fs.fstatSync(inputFd, { bigint: true });
    if (initial.size !== final.size || initial.mtimeNs !== final.mtimeNs) {
      throw new Error('Input changed during the operation');
    }
    report.host_reads = reads;
    report.largest_read_bytes = largestRead;
    if (outputFd !== undefined) fs.fsyncSync(outputFd);
    completed = true;
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } finally {
    if (inputFd !== undefined) fs.closeSync(inputFd);
    if (outputFd !== undefined) fs.closeSync(outputFd);
    // Delete only the new file exclusively created by this invocation.
    if (createdOutput && !completed) fs.unlinkSync(settings.output);
  }
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
