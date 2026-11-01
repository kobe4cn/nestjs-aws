import { z } from 'zod';

export const signUpSchema = z.object({
  email: z.email(),
  name: z.string(),
  password: z.string().min(12).max(128),
  userRoles: z.array(z.number()).optional(),
});
export type SignUpDto = z.infer<typeof signUpSchema>;

export const signInSchema = z.object({
  email: z.email(),
  password: z.string(),
});
export type SignInDto = z.infer<typeof signInSchema>;

export const emailSchema = z.object({
  email: z.email(),
});
export type EmailDto = z.infer<typeof emailSchema>;

/** The token from the reset link, and the new password, under the sign-up rules. */
export const resetPasswordSchema = z.object({
  token: z.string(),
  password: z.string().min(12).max(128),
});
export type ResetPasswordDto = z.infer<typeof resetPasswordSchema>;
