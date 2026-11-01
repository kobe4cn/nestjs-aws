import z from 'zod';
export const createPermissionSchema = z.object({
  name: z.string(),
  controller: z.string(),
  action: z.string(),
  description: z.string().optional(),
});
export type CreatePermissionDto = z.infer<typeof createPermissionSchema>;
