import z from 'zod';

export const updateRoleSchema = z.object({
  name: z.string(),
  description: z.string().optional(),
});
export type UpdateRoleDto = z.infer<typeof updateRoleSchema>;
