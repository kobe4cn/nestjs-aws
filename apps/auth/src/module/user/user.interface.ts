export interface UserAdapter {
  find(filter?: any): Promise<any[]>;
  create(userObj: any): Promise<any>;
  update(userObj: any): Promise<any>;
  delete(id: string): Promise<any>;
  findRow(filter?: any): Promise<any>;
  findById(id: number): Promise<any>;
  createUserWithRole(createUserDto: any): Promise<any>;
  findUserAuthorization(email: string): Promise<any>;
  findByIdAuth(id: number): Promise<any>;
}

export interface UserEntity {
  id: number;
  email: string;
  hashedPassword?: string;
  name: string;
  createdAt: Date;
  emailVerified: boolean;
}
