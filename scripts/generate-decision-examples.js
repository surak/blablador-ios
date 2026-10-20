// Regenerates app/src/main/assets/decision-examples.json from decision-model-frontend's presets.
// Usage: node scripts/generate-decision-examples.js ../decision-model-frontend/static/app.js
const fs = require("fs");
const path = require("path");

const src = fs.readFileSync(process.argv[2], "utf8");
const start = src.indexOf("const PRESETS = [");
let depth = 0, end = -1, inString = null;
const open = src.indexOf("[", start);
for (let j = open; j < src.length; j++) {
  const c = src[j];
  if (inString) { if (c === "\\") { j++; continue; } if (c === inString) inString = null; continue; }
  if (c === '"' || c === "'" || c === "`") { inString = c; continue; }
  if (c === "[") depth++; else if (c === "]" && --depth === 0) { end = j + 1; break; }
}
const presets = Function("return " + src.slice(open, end))();
function category(p) {
  return p.category || (p.name.startsWith("Hello world") ? "Getting started"
    : p.name.startsWith("Business:") ? "Business"
    : p.questions.model_selection || p.questions.endpoint_family || p.questions.route_selection ? "Routing"
    : "Triage & safety");
}
const out = presets.filter(p => p.name !== "Blank starter").map(p => ({
  name: p.name.replace(/^Hello world: /, "").replace(/^Business: /, ""),
  category: category(p),
  description: p.description || null,
  state: p.state,
  json: p.stateMode === "json",
  questions: Object.entries(p.questions).map(([id, q]) => ({
    id, type: q.type, instructions: q.instructions,
    options: q.type === "choice" ? Object.entries(q.criteria).map(([key, text]) => ({ key, text })) : null,
    levels: q.type === "score" ? q.criteria : null,
  })),
}));
const order = ["Getting started","Routing","Triage & safety","Business","Workflow","Documents","Retrieval & agents","Data quality","Engineering","Operations","Product","Science"];
out.sort((a, b) => order.indexOf(a.category) - order.indexOf(b.category));
fs.writeFileSync(path.join(__dirname, "../app/src/main/assets/decision-examples.json"), JSON.stringify(out));
const cats = {}; out.forEach(p => cats[p.category] = (cats[p.category] || 0) + 1); console.log(out.length, cats);
