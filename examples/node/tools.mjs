#!/usr/bin/env node
// Tool calling: the model calls JavaScript functions while it answers.
//   node tools.mjs "Is it warmer in Prague or in Oslo right now?"
import { AppleFoundationModels, tool } from 'afm-bridge'
import { NodeStdioTransport } from 'afm-bridge/node'
import { zodSchema } from 'afm-bridge/zod'
import { z } from 'zod'

// A fake weather service; replace with a real API call.
const temperatures = { prague: 14, oslo: 6, lisbon: 21 }

const getWeather = tool({
  name: 'getWeather',
  description: 'Get the current temperature in degrees Celsius for a city',
  parameters: zodSchema(z.object({ city: z.string().describe('City name, e.g. Prague') })),
  execute: async ({ city }, { signal }) => {
    console.error(`[tool] getWeather(${city})`)
    signal.throwIfAborted()
    const temperatureC = temperatures[city.toLowerCase()]
    return temperatureC === undefined ? { city, error: 'unknown city' } : { city, temperatureC }
  },
})

const question = process.argv.slice(2).join(' ') || 'Is it warmer in Prague or in Oslo right now?'
const afm = new AppleFoundationModels({ transport: new NodeStdioTransport() })
try {
  const session = await afm.createSession({
    instructions: 'Use the tools to answer. Answer in one sentence.',
    tools: [getWeather],
  })
  console.log(await session.respond(question))
} catch (error) {
  console.error(`${error.name}: ${error.message}`)
  process.exitCode = 1
} finally {
  await afm.close()
}
