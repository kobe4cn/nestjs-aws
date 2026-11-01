import z from 'zod';

export const createUserSchema = z.object({
  email: z.email(),
  hashedPassword: z.string(),
  name: z.string(),
  //   createdAt: Date;
  emailVerified: z.boolean().default(false).optional(),
  userRoles: z.array(z.number()).optional(),
});

export type CreateUserDto = z.infer<typeof createUserSchema>;
