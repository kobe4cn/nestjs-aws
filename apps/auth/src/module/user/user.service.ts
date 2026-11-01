import { Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { UserRepository } from './user.repository';
import { AuthenticationContext } from '@nestjs/authentication';
import { User } from '@app/common/database/typeorm/entity/user.entity';
@Injectable()
export class UserService {
  constructor(
    private userRepository: UserRepository,
    private readonly authenticationContext: AuthenticationContext,
  ) {}

  // async insertUser(createUserDto: CreateUserDto): Promise<UserModel> {
  //   return this.userRepository.create(createUserDto);
  // }

  async findAllUser(): Promise<User[]> {
    return await this.userRepository.find();
  }
  //   async findAllUser2(): Promise<User[]> {
  //     return await this.userRepository2.find();
  //   }

  async createUser(user: User): Promise<User> {
    return await this.userRepository.create(user);
  }

  async findMe(): Promise<any> {
    const { id } = this.authenticationContext.requireUser();
    return id;
  }
  //   //   async createUser2(user: User): Promise<User> {
  //   //     return await this.userRepository2.save(user);
  //   //   }

  //   async createPost(post: Post): Promise<Post> {
  //     return await this.postRepository.save(post);
  //   }

  //   async findAllPost(): Promise<Post[]> {
  //     return await this.postRepository.find();
  //   }

  //   async findPostWithUser(id: number): Promise<Post[]> {
  //     return await this.postRepository.find({
  //       where: {
  //         author: { id: id },
  //       },
  //     });
  //   }

  //   async updateUser(user: User): Promise<User> {
  //     return await this.userRepository.save(user);
  //   }

  //   async updatePost(post: Post): Promise<Post> {
  //     return await this.postRepository.save(post);
  //   }

  //   async deleteUser(user: User): Promise<User> {
  //     return await this.userRepository.remove(user);
  //   }

  //   async deletePost(post: Post): Promise<Post> {
  //     return await this.postRepository.remove(post);
  //   }

  //   async createCat(cat: CreateCatDto): Promise<Cat> {
  //     const createCat = await this.catModel.create(cat);
  //     return createCat.save();
  //   }

  //   async findMongoCat(): Promise<Cat[]> {
  //     return await this.catModel.find().exec();
  //   }
}
