import z from 'zod';
export const apiKeysSchemas = z
  .object({
    id: z.string(),

    // userId: z.string(),

    // hash: z.string(),
    createAt: z.date(),
    expiresAt: z.date(),
  })
  
export type ApiKeyDto = z.infer<typeof apiKeysSchemas>;
