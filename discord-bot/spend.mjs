// What the bot's model calls cost, and the monthly budget.  Every call through the client goes on the meter
// (metered()): looks, sorting, tags, translations, release checks.  Only the looks wait for money: each day they may
// spend what is left of the month over the days left in it (today too), so a quiet day leaves more for the rest and a
// busy week can't spend the month.
import fs from 'node:fs';

// $ per million tokens: input, output, cache write (5 minutes), cache write (1 hour), cache read
const PRICES = {
  'claude-opus-5-5': [4, 20, 5, 8, 0.2],
  'claude-sonnet-5-5': [2, 10, 2.5, 4, 0.2],
  'claude-haiku-5-5': [0.1, 0.5, 0.125, 0.2, 0.01],   // a prompt of up to 100K tokens; five times that above
};

/** a response's cost in $ from its usage, or null for a model without prices */
export function costOf(model, u) {
  const key = Object.keys(PRICES).find(k => model?.startsWith(k));
  if (!key || !u) return null;
  const w1h = u.cache_creation?.ephemeral_1h_input_tokens ?? 0;
  const w5m = (u.cache_creation_input_tokens ?? 0) - w1h, read = u.cache_read_input_tokens ?? 0;
  const long = key === 'claude-haiku-5-5' && u.input_tokens + w5m + w1h + read > 100_000 ? 5 : 1;
  const [i, o, c5m, c1h, r] = PRICES[key];
  return long * (u.input_tokens * i + u.output_tokens * o + w5m * c5m + w1h * c1h + read * r) / 1e6;
}

/** the client with every messages.create, plain and beta, on the meter: onCost($) after each answer */
export function metered(client, onCost) {
  const unpriced = new Set();
  for (const api of [client.messages, client.beta.messages]) {
    const create = api.create.bind(api);
    api.create = (body, options) => {
      const p = create(body, options);
      p.then(res => {
        const model = res?.model ?? body.model, cost = costOf(model, res?.usage);
        if (cost == null && !unpriced.has(model)) { unpriced.add(model); console.error(`[spend] no prices for ${model}: its calls count as nothing`); }
        onCost(cost ?? 0);
      }, () => {});
      return p;
    };
  }
  return client;
}

/** the month's spending (UTC), kept in a file over restarts */
export class Spend {
  constructor(file, monthly) {
    this.file = file; this.monthly = monthly;
    try { this.s = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { this.s = {}; }
  }
  roll() {
    const now = new Date().toISOString(), month = now.slice(0, 7), day = now.slice(0, 10);
    if (this.s.month !== month) this.s = { month, spent: 0, day, today: 0 };
    else if (this.s.day !== day) Object.assign(this.s, { day, today: 0 });
    return this.s;
  }
  add(dollars) {
    const s = this.roll();
    s.spent += dollars; s.today += dollars;
    fs.writeFileSync(this.file + '.tmp', JSON.stringify(s));
    fs.renameSync(this.file + '.tmp', this.file);
  }
  /** what today may spend: what is left of the month over its days left, today included */
  share() {
    const s = this.roll(), now = new Date();
    const daysLeft = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0)).getUTCDate() - now.getUTCDate() + 1;
    return Math.max(0, this.monthly - (s.spent - s.today)) / daysLeft;
  }
  allows() { return this.roll().today < this.share(); }
  get today() { return this.roll().today; }
  get month() { return this.roll().spent; }
}
