#!/usr/bin/env node
// Structured output: the model fills a Zod schema, afm-bridge validates the result.
//   node structured.mjs "a fantasy novel about dragons"
import { AppleFoundationModels } from 'afm-bridge'
import { NodeStdioTransport } from 'afm-bridge/node'
import { zodSchema } from 'afm-bridge/zod'
import { z } from 'zod'

const Book = z.object({
  title: z.string(),
  author: z.string(),
  year: z.number().int().min(1900).max(2030),
  genre: z.enum(['fantasy', 'science fiction', 'mystery', 'romance', 'other']),
  subtitle: z.string().nullable(),
  chapters: z
    .array(z.object({ title: z.string(), pages: z.number().int().min(1) }))
    .min(2)
    .max(4),
})

const topic = process.argv.slice(2).join(' ') || 'a mystery novel set in Prague'
const afm = new AppleFoundationModels({ transport: new NodeStdioTransport() })
try {
  const session = await afm.createSession()
  // Watch the object fill in while it streams, then print the validated result.
  let last = ''
  for await (const chunk of session.stream(`Invent ${topic}.`, { schema: zodSchema(Book) })) {
    if (chunk.done) {
      console.log(JSON.stringify(chunk.content, null, 2))
    } else if (chunk.partial.title && chunk.partial.title !== last) {
      last = chunk.partial.title
      console.error(`[streaming] title: ${last}`)
    }
  }
} catch (error) {
  console.error(`${error.name}: ${error.message}`)
  process.exitCode = 1
} finally {
  await afm.close()
}
