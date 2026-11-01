export abstract class UserRepositoryAbstractClass {
  abstract find(): Promise<any[]>;
  abstract create(userObj: any): Promise<any>;
  abstract update(userObj: any): Promise<any>;
  abstract delete(id: string): Promise<any>;
  abstract findRow(filter: any): Promise<any>;
  abstract findById(id: number): Promise<any>;
  abstract createUserWithRole(createUserDto: any): Promise<any>;
  abstract findUserAuthorization(email: string): Promise<any>;
  abstract findByIdAuth(id: number): Promise<any>;
}
