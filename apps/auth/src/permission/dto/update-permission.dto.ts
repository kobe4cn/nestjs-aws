import z from 'zod';
export const updatePermissionSchema = z.object({
  name: z.string(),
  controller: z.string(),
  action: z.string(),
  description: z.string().optional(),
});
export type UpdatePermissionDto = z.infer<typeof updatePermissionSchema>;
