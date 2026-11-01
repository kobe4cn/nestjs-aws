import z from 'zod';

export const createRoleSchema = z.object({
  //   id: z.number(),
  name: z.string(),
  description: z.string().optional(),
  rolePermission: z.array(z.number()).optional(),
});
export type CreateRoleDto = z.infer<typeof createRoleSchema>;
