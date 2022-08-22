// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_dartlang_org.backend;

import 'dart:async';
import 'dart:io';

import 'package:_pub_shared/data/account_api.dart' as account_api;
import 'package:_pub_shared/data/package_api.dart' as api;
import 'package:clock/clock.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:gcloud/storage.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:pool/pool.dart';
import 'package:pub_dev/job/backend.dart';
import 'package:pub_package_reader/pub_package_reader.dart';
import 'package:pub_semver/pub_semver.dart';

import '../account/backend.dart';
import '../account/consent_backend.dart';
import '../account/models.dart' show User;
import '../admin/backend.dart';
import '../audit/models.dart';
import '../frontend/email_sender.dart';
import '../publisher/backend.dart';
import '../service/secret/backend.dart';
import '../shared/configuration.dart';
import '../shared/datastore.dart';
import '../shared/email.dart';
import '../shared/exceptions.dart';
import '../shared/redis_cache.dart' show cache;
import '../shared/storage.dart';
import '../shared/urls.dart' as urls;
import '../shared/utils.dart';
import '../tool/utils/dart_sdk_version.dart';
import 'model_properties.dart';
import 'models.dart';
import 'name_tracker.dart';
import 'overrides.dart';
import 'upload_signer_service.dart';

// The maximum stored length of `README.md` and other user-provided file content
// that is stored separately in the database.
final maxAssetContentLength = 128 * 1024;

/// The maximum number of versions a package is allowed to have.
final _defaultMaxVersionsPerPackage = 1000;

final Logger _logger = Logger('pub.cloud_repository');
final _validGithubUserOrRepoRegExp =
    RegExp(r'^[a-z0-9\-\._]+$', caseSensitive: false);

/// Sets the package backend service.
void registerPackageBackend(PackageBackend backend) =>
    ss.register(#_packageBackend, backend);

/// The active package backend service.
PackageBackend get packageBackend =>
    ss.lookup(#_packageBackend) as PackageBackend;

/// Represents the backend for the pub site.
class PackageBackend {
  final DatastoreDB db;
  final Storage _storage;

  /// The Cloud Storage bucket to use for uploaded package content.
  /// The following files are present:
  /// - `packages/$package-$version.tar.gz` (package archive)
  /// - `tmp/$guid` (incoming package archive that was uploaded, but not yet processed)
  final Bucket _bucket;

  /// The Cloud Storage bucket to use for incoming package archives.
  /// The following files are present:
  /// - `tmp/$guid` (incoming package archive that was uploaded, but not yet processed)
  final Bucket _incomingBucket;

  /// The Cloud Storage bucket to use for canonical package archives.
  /// The following files are present:
  /// - `packages/$package-$version.tar.gz` (package archive)
  final Bucket _canonicalBucket;

  /// The Cloud Storage bucket to use for public package archives.
  /// The following files are present:
  /// - `packages/$package-$version.tar.gz` (package archive)
  final Bucket _publicBucket;

  @visibleForTesting
  int maxVersionsPerPackage = _defaultMaxVersionsPerPackage;

  PackageBackend(
    this.db,
    this._storage,
    this._bucket,
    this._incomingBucket,
    this._canonicalBucket,
    this._publicBucket,
  );

  /// Whether the package exists and is not blocked or deleted.
  Future<bool> isPackageVisible(String package) async {
    return (await cache.packageVisible(package).get(() async {
      final p = await db
          .lookupOrNull<Package>(db.emptyKey.append(Package, id: package));
      return p != null && p.isVisible;
    }))!;
  }

  /// Retrieves the names of all packages that need to be included in sitemap.txt.
  Stream<String> sitemapPackageNames() {
    final query = db.query<Package>()
      ..filter(
          'updated >', clock.now().toUtc().subtract(robotsVisibilityMaxAge));
    return query
        .run()
        .where((p) => p.isVisible)
        .where((p) => p.isIncludedInRobots)
        .where((p) => !isSoftRemoved(p.name!))
        .map((p) => p.name!);
  }

  /// Retrieves package versions ordered by their published date descending.
  Future<List<PackageVersion>> latestPackageVersions(
      {int offset = 0, required int limit}) async {
    final query = db.query<PackageVersion>()
      ..order('-created')
      ..offset(offset)
      ..limit(limit);
    final versions = await query.run().toList();
    final results = <PackageVersion>[];
    for (final v in versions) {
      if (isSoftRemoved(v.package)) continue;
      if (!(await isPackageVisible(v.package))) continue;
      results.add(v);
    }
    return results;
  }

  /// Returns the latest stable version of a package.
  Future<String?> getLatestVersion(String package) async {
    return cache.packageLatestVersion(package).get(() async {
      final p = await db
          .lookupOrNull<Package>(db.emptyKey.append(Package, id: package));
      return p?.latestVersion;
    });
  }

  /// Looks up a package by name.
  ///
  /// Returns `null` if the package doesn't exist.
  Future<Package?> lookupPackage(String packageName) async {
    final packageKey = db.emptyKey.append(Package, id: packageName);
    return await db.lookupOrNull<Package>(packageKey);
  }

  /// Looks up a moderated package by name.
  ///
  /// Returns `null` if the package doesn't exist.
  Future<ModeratedPackage?> lookupModeratedPackage(String packageName) async {
    final packageKey = db.emptyKey.append(ModeratedPackage, id: packageName);
    return await db.lookupOrNull<ModeratedPackage>(packageKey);
  }

  /// Looks up a package by name.
  Future<List<Package>> lookupPackages(Iterable<String> packageNames) async {
    return (await db.lookup(packageNames
            .map((p) => db.emptyKey.append(Package, id: p))
            .toList()))
        .cast();
  }

  /// List all packages where the [userId] is an uploader.
  Future<PackageListPage> listPackagesForUser(
    String userId, {
    String? next,
    int limit = 10,
  }) async {
    final query = db.query<Package>()
      ..filter('uploaders =', userId)
      ..order('name')
      ..limit(limit + 1);
    if (next != null) {
      query.filter('name >=', next);
    }
    final packages = await query.run().toList();
    return PackageListPage(
      packages: packages.take(limit).map((p) => p.name!).toList(),
      nextPackage: packages.length <= limit ? null : packages.last.name!,
    );
  }

  /// Returns the latest releases info of a package.
  Future<LatestReleases> latestReleases(Package package) async {
    // TODO: implement runtimeVersion-specific release calculation
    return package.latestReleases;
  }

  /// Looks up a specific package version.
  ///
  /// Returns null if the version is not a semantic version or if the version
  /// entity does not exists in the datastore.
  Future<PackageVersion?> lookupPackageVersion(
      String package, String version) async {
    final canonicalVersion = canonicalizeVersion(version);
    if (canonicalVersion == null) return null;
    final packageVersionKey = db.emptyKey
        .append(Package, id: package)
        .append(PackageVersion, id: canonicalVersion);
    return await db.lookupOrNull<PackageVersion>(packageVersionKey);
  }

  /// Looks up a specific package version's info object.
  ///
  /// Returns null if the [version] is not a semantic version or if the info
  /// entity does not exists in the datastore.
  Future<PackageVersionInfo?> lookupPackageVersionInfo(
      String package, String version) async {
    final canonicalVersion = canonicalizeVersion(version);
    if (canonicalVersion == null) return null;
    final qvk =
        QualifiedVersionKey(package: package, version: canonicalVersion);
    return await db.lookupOrNull<PackageVersionInfo>(
        db.emptyKey.append(PackageVersionInfo, id: qvk.qualifiedVersion));
  }

  /// Looks up a specific package version's asset object.
  ///
  /// Returns null if the [version] is not a semantic version or if the asset
  /// entity does not exists in the Datastore.
  Future<PackageVersionAsset?> lookupPackageVersionAsset(
      String package, String version, String assetKind) async {
    final canonicalVersion = canonicalizeVersion(version);
    if (canonicalVersion == null) return null;
    final qvk =
        QualifiedVersionKey(package: package, version: canonicalVersion);
    return await db.lookupOrNull<PackageVersionAsset>(
        db.emptyKey.append(PackageVersionAsset, id: qvk.assetId(assetKind)));
  }

  /// Looks up the qualified [versions].
  Future<List<PackageVersion?>> lookupVersions(
      Iterable<QualifiedVersionKey> versions) async {
    return await db.lookup<PackageVersion>(
      versions
          .map((k) => db.emptyKey
              .append(Package, id: k.package)
              .append(PackageVersion, id: k.version))
          .toList(),
    );
  }

  /// Looks up all versions of a package.
  Future<List<PackageVersion>> versionsOfPackage(String packageName) async {
    final packageKey = db.emptyKey.append(Package, id: packageName);
    final query = db.query<PackageVersion>(ancestorKey: packageKey);
    return await query.run().toList();
  }

  /// List the versions of [package] that are published in the last N [days].
  Future<List<PackageVersion>> _listVersionsFromPastDays(
    String package, {
    required int days,
    bool Function(PackageVersion pv)? where,
  }) async {
    final packageKey = db.emptyKey.append(Package, id: package);
    final query = db.query<PackageVersion>(ancestorKey: packageKey)
      ..filter(
          'created >=', clock.now().toUtc().subtract(Duration(days: days)));
    return await query.run().where((pv) => where == null || where(pv)).toList();
  }

  /// List retractable versions.
  Future<List<PackageVersion>> listRetractableVersions(String package) async {
    return await _listVersionsFromPastDays(package,
        days: 7, where: (pv) => pv.canBeRetracted);
  }

  /// List versions that are retracted and the retraction is recent, it can be undone.
  Future<List<PackageVersion>> listRecentlyRetractedVersions(
      String package) async {
    return await _listVersionsFromPastDays(package,
        days: 14, where: (pv) => pv.canUndoRetracted);
  }

  /// Get a [Uri] which can be used to download a tarball of the pub package.
  Future<Uri> downloadUrl(String package, String version) async {
    InvalidInputException.checkSemanticVersion(version);
    final cv = canonicalizeVersion(version);
    // NOTE: We should maybe check for existence first?
    // return storage.bucket(bucket).info(object)
    //     .then((info) => info.downloadLink);
    final object = tarballObjectName(package, Uri.encodeComponent(cv!));
    return Uri.parse(_publicBucket.objectUrl(object));
  }

  /// Updates the stable, prerelease and preview versions of [package].
  ///
  /// Returns true if the values did change.
  Future<bool> updatePackageVersions(
    String package, {
    Version? dartSdkVersion,
  }) async {
    _logger.info("Checking Package's versions fields for package `$package`.");
    final pkgKey = db.emptyKey.append(Package, id: package);
    dartSdkVersion ??= (await getDartSdkVersion()).semanticVersion;

    // ordered version list by publish date
    final versions =
        await db.query<PackageVersion>(ancestorKey: pkgKey).run().toList();

    final updated = await withRetryTransaction(db, (tx) async {
      final p = await tx.lookupOrNull<Package>(pkgKey);
      if (p == null) {
        throw NotFoundException.resource('package "$package"');
      }

      final changed = p.updateLatestVersionReferences(versions,
          dartSdkVersion: dartSdkVersion!);

      if (!changed) {
        _logger.info('No version field updates for package `$package`.');
        return false;
      }

      _logger.info('Updating version fields for package `$package`.');
      tx.insert(p);
      return true;
    });
    if (updated) {
      await purgePackageCache(package);
    }
    return updated;
  }

  /// Updates the stable, prerelase and preview versions of all package.
  ///
  /// Return the number of updated packages.
  Future<int> updateAllPackageVersions(
      {Version? dartSdkVersion, int? concurrency}) async {
    final pool = Pool(concurrency ?? 1);
    var count = 0;
    final futures = <Future>[];
    await for (final p in db.query<Package>().run()) {
      final package = p.name!;
      final f = pool.withResource(() async {
        final updated = await updatePackageVersions(package,
            dartSdkVersion: dartSdkVersion);
        if (updated) count++;
      });
      futures.add(f);
    }
    await Future.wait(futures);
    await pool.close();
    return count;
  }

  /// Updates [options] on [package].
  Future<void> updateOptions(String package, api.PkgOptions options) async {
    final user = await requireAuthenticatedUser();
    // Validate replacedBy parameter
    final replacedBy = options.replacedBy?.trim() ?? '';
    InvalidInputException.check(package != replacedBy,
        '"replacedBy" must point to a different package.');
    if (replacedBy.isNotEmpty) {
      InvalidInputException.check(options.isDiscontinued == true,
          '"replacedBy" must be set only with "isDiscontinued": true.');

      final rp = await lookupPackage(replacedBy);
      InvalidInputException.check(rp != null && rp.isVisible,
          'Package specified by "replaceBy" does not exists.');
      InvalidInputException.check(rp != null && !rp.isDiscontinued,
          'Package specified by "replaceBy" must not be discontinued.');
    }

    final pkgKey = db.emptyKey.append(Package, id: package);
    String? latestVersion;
    await withRetryTransaction(db, (tx) async {
      final p = await tx.lookupOrNull<Package>(pkgKey);
      if (p == null) {
        throw NotFoundException.resource(package);
      }
      latestVersion = p.latestVersion;

      // Check that the user is admin for this package.
      await checkPackageAdmin(p, user.userId);

      final optionsChanges = <String>[];
      if (options.isDiscontinued != null &&
          options.isDiscontinued != p.isDiscontinued) {
        p.isDiscontinued = options.isDiscontinued!;
        if (!p.isDiscontinued) {
          p.replacedBy = null;
        }
        optionsChanges.add('discontinued');
      }
      if (options.isDiscontinued == true &&
          (p.replacedBy ?? '') != replacedBy) {
        p.replacedBy = replacedBy.isEmpty ? null : replacedBy;
        optionsChanges.add('replacedBy');
      }
      if (options.isUnlisted != null && options.isUnlisted != p.isUnlisted) {
        p.isUnlisted = options.isUnlisted!;
        optionsChanges.add('unlisted');
      }

      if (optionsChanges.isEmpty) {
        return;
      }

      p.updated = clock.now().toUtc();
      _logger.info('Updating $package options: '
          'isDiscontinued: ${p.isDiscontinued} '
          'isUnlisted: ${p.isUnlisted}');
      tx.insert(p);
      tx.insert(AuditLogRecord.packageOptionsUpdated(
        package: p.name!,
        user: user,
        options: optionsChanges,
      ));
    });
    await purgePackageCache(package);
    await jobBackend.trigger(JobService.analyzer, package,
        version: latestVersion);
  }

  /// Updates [options] on [package]/[version], assuming the current user
  /// has proper rights, and the option change is allowed.
  Future<void> updatePackageVersionOptions(
    String package,
    String version,
    api.VersionOptions options,
  ) async {
    final user = await requireAuthenticatedUser();

    final pkgKey = db.emptyKey.append(Package, id: package);
    final versionKey = pkgKey.append(PackageVersion, id: version);
    await withRetryTransaction(db, (tx) async {
      final p = await tx.lookupOrNull<Package>(pkgKey);
      if (p == null) {
        throw NotFoundException.resource(package);
      }
      // Check that the user is admin for this package.
      await checkPackageAdmin(p, user.userId);

      final pv = await tx.lookupOrNull<PackageVersion>(versionKey);
      if (pv == null) {
        throw NotFoundException.resource(version);
      }

      if (options.isRetracted != null &&
          options.isRetracted != pv.isRetracted) {
        if (options.isRetracted!) {
          InvalidInputException.check(pv.canBeRetracted,
              'Can\'t retract package "$package" version "$version".');
        } else {
          InvalidInputException.check(pv.canUndoRetracted,
              'Can\'t undo retraction of package "$package" version "$version".');
        }
        await doUpdateRetractedStatus(user, tx, p, pv, options.isRetracted!);
      }
    });
    await purgePackageCache(package);
  }

  /// Verifies an update to the credential-less publishing settings and
  /// updates the Datastore entity if everything is valid.
  Future<api.AutomatedPublishing> setAutomatedPublishing(
      String package, api.AutomatedPublishing body) async {
    final user = await requireAuthenticatedUser();
    return await withRetryTransaction(db, (tx) async {
      final p = await tx
          .lookupOrNull<Package>(db.emptyKey.append(Package, id: package));
      if (p == null) {
        throw NotFoundException.resource(package);
      }
      // Check that the user is admin for this package.
      await checkPackageAdmin(p, user.userId);

      final github = body.github;
      if (github != null) {
        final isEnabled = github.isEnabled ?? false;
        // normalize input values
        final repository = github.repository?.trim() ?? '';
        github.repository = repository;

        InvalidInputException.check(!isEnabled || repository.isNotEmpty,
            'The `repository` field must not be empty when enabled.');

        if (repository.isNotEmpty) {
          final parts = repository.split('/');
          InvalidInputException.check(parts.length == 2,
              'The `repository` field must follow the `<owner>/<repository>` pattern.');
          InvalidInputException.check(
              _validGithubUserOrRepoRegExp.hasMatch(parts[0]) &&
                  _validGithubUserOrRepoRegExp.hasMatch(parts[1]),
              'The `repository` field has invalid characters.');
        }
      }

      // finalize changes
      p.automatedPublishing = body;
      p.updated = clock.now().toUtc();
      tx.insert(p);
      tx.insert(AuditLogRecord.packagePublicationAutomationUpdated(
        package: p.name!,
        user: user,
      ));
      return p.automatedPublishing;
    });
  }

  /// Updates the retracted status inside a transaction.
  ///
  /// This is a helper method, and should be used only after appropriate
  /// input validation.
  Future<void> doUpdateRetractedStatus(User user, TransactionWrapper tx,
      Package p, PackageVersion pv, bool isRetracted) async {
    pv.isRetracted = isRetracted;
    pv.retracted = isRetracted ? clock.now() : null;

    // Update references to latest versions if the retracted version was
    // the latest version or the restored version is newer than the latest.
    if (p.mayAffectLatestVersions(pv.semanticVersion)) {
      final versions = await tx.query<PackageVersion>(p.key).run().toList();
      final currentDartSdk = await getDartSdkVersion();
      p.updateLatestVersionReferences(
        versions,
        dartSdkVersion: currentDartSdk.semanticVersion,
        replaced: pv,
      );
    }

    _logger.info(
        'Updating ${p.name} ${pv.version} options: isRetracted: $isRetracted');

    tx.insert(p);
    tx.insert(pv);
    tx.insert(AuditLogRecord.packageVersionOptionsUpdated(
      package: p.name!,
      version: pv.version!,
      user: user,
      options: ['retracted'],
    ));
  }

  /// Whether [userId] is a package admin (through direct uploaders list or
  /// publisher admin).
  ///
  /// Returns false if the user is not an admin.
  Future<bool> isPackageAdmin(
    Package p,
    String? userId, {
    AuthenticatedAgent? agent,
  }) async {
    if (agent is AuthenticatedGithubAction) {
      // TODO: check if the JWT token matches the automated publishing settings on the package.
      return false;
    }
    if (agent is AuthenticatedUser) {
      userId ??= agent.user.userId;
    }
    if (userId == null) {
      return false;
    }
    if (p.publisherId == null) {
      return p.containsUploader(userId);
    } else {
      final publisherId = p.publisherId!;
      final publisher = await publisherBackend.getPublisher(publisherId);
      if (publisher == null) {
        return false;
      }
      return await publisherBackend.isMemberAdmin(publisher, userId);
    }
  }

  /// Whether the [userId] is a package admin (through direct uploaders list or
  /// publisher admin).
  ///
  /// Throws AuthenticationException if the user is provided.
  /// Throws AuthorizationException if the user is not an admin for the package.
  Future<void> checkPackageAdmin(Package package, String? userId) async {
    if (userId == null) {
      throw AuthenticationException.authenticationRequired();
    }
    if (!await isPackageAdmin(package, userId)) {
      throw AuthorizationException.userIsNotAdminForPackage(package.name!);
    }
  }

  /// Returns the publisher info of a given package.
  Future<api.PackagePublisherInfo> getPublisherInfo(String packageName) async {
    checkPackageVersionParams(packageName);
    final key = db.emptyKey.append(Package, id: packageName);
    final package = (await db.lookup<Package>([key])).single;
    if (package == null) {
      throw NotFoundException.resource('package "$packageName"');
    }
    return _asPackagePublisherInfo(package);
  }

  /// Returns the number of likes of a given package.
  Future<account_api.PackageLikesCount> getPackageLikesCount(
      String packageName) async {
    checkPackageVersionParams(packageName);
    final key = db.emptyKey.append(Package, id: packageName);
    final package = await db.lookupOrNull<Package>(key);
    if (package == null) {
      throw NotFoundException.resource('package "$packageName"');
    }
    return account_api.PackageLikesCount(
        package: packageName, likes: package.likes);
  }

  /// Sets/updates the publisher of a package.
  Future<api.PackagePublisherInfo> setPublisher(
      String packageName, api.PackagePublisherInfo request) async {
    InvalidInputException.checkNotNull(request.publisherId, 'publisherId');
    final user = await requireAuthenticatedUser();

    final key = db.emptyKey.append(Package, id: packageName);
    final preTxPackage = await requirePackageAdmin(packageName, user.userId);
    await requirePublisherAdmin(request.publisherId, user.userId);
    if (preTxPackage.publisherId == request.publisherId) {
      // If desired publisherId is already the current publisherId, then we're already done.
      return _asPackagePublisherInfo(preTxPackage);
    }

    final preTxUploaderEmails = preTxPackage.publisherId == null
        ? await accountBackend.getEmailsOfUserIds(preTxPackage.uploaders!)
        : await publisherBackend
            .getAdminMemberEmails(preTxPackage.publisherId!);
    final newPublisherAdminEmails =
        await publisherBackend.getAdminMemberEmails(request.publisherId!);
    final allAdminEmails = <String>{
      ...preTxUploaderEmails.whereType<String>(),
      ...newPublisherAdminEmails.whereType<String>(),
    };

    EmailMessage? email;
    String? currentPublisherId;
    final rs = await withRetryTransaction(db, (tx) async {
      final package = await tx.lookupValue<Package>(key);
      if (package.publisherId == request.publisherId) {
        // If desired publisherId is already the current publisherId, then we're already done.
        return _asPackagePublisherInfo(package);
      }
      currentPublisherId = package.publisherId;
      package.publisherId = request.publisherId;
      package.uploaders?.clear();
      package.updated = clock.now().toUtc();

      tx.insert(package);
      tx.insert(AuditLogRecord.packageTransferred(
        user: user,
        package: package.name!,
        fromPublisherId: currentPublisherId,
        toPublisherId: package.publisherId!,
      ));

      email = createPackageTransferEmail(
        packageName: packageName,
        activeUserEmail: user.email!,
        oldPublisherId: currentPublisherId,
        newPublisherId: package.publisherId!,
        authorizedAdmins:
            allAdminEmails.map((email) => EmailAddress(null, email)).toList(),
      );
      return _asPackagePublisherInfo(package);
    });
    await purgePublisherCache(publisherId: request.publisherId);
    await purgePackageCache(packageName);

    if (email != null) {
      await emailSender.sendMessage(email!);
    }
    if (currentPublisherId != null) {
      await purgePublisherCache(publisherId: currentPublisherId);
    }

    return rs;
  }

  /// Moves the package out of its current publisher.
  Future<api.PackagePublisherInfo> removePublisher(String packageName) async {
    final user = await requireAuthenticatedUser();
    final package = await requirePackageAdmin(packageName, user.userId);
    if (package.publisherId == null) {
      return _asPackagePublisherInfo(package);
    }
    await requirePublisherAdmin(package.publisherId, user.userId);
//  Code commented out while we decide if this feature is something we want to
//  support going forward.
//
//    final key = db.emptyKey.append(Package, id: packageName);
//    final rs = await db.withTransaction((tx) async {
//      final package = (await db.lookup<Package>([key])).single;
//      package.publisherId = null;
//      package.uploaders = [user.userId];
//      package.updated = clock.now().toUtc();
//      // TODO: store PackageTransferred History entry.
//      tx.queueMutations(inserts: [package]);
//      await tx.commit();
//      return _asPackagePublisherInfo(package);
//    });
//    await purgePublisherCache(package.publisherId);
//    await invalidatePackageCache(packageName);
//    return rs as api.PackagePublisherInfo;
    throw NotImplementedException();
  }

  /// Returns the known versions of [package].
  /// The available versions are sorted by their semantic version number (ascending).
  ///
  /// Used in `pub` client for finding which versions exist.
  Future<api.PackageData> listVersions(String package) async {
    final pkg = await packageBackend.lookupPackage(package);
    if (pkg == null || pkg.isNotVisible) {
      throw NotFoundException.resource('package "$package"');
    }
    final packageVersions = await packageBackend.versionsOfPackage(package);
    if (packageVersions.isEmpty) {
      throw NotFoundException.resource('package "$package"');
    }
    packageVersions
        .sort((a, b) => a.semanticVersion.compareTo(b.semanticVersion));
    final latest = packageVersions.firstWhere(
      (pv) => pv.version == pkg.latestVersion,
      orElse: () => packageVersions.last,
    );
    return api.PackageData(
      name: package,
      isDiscontinued: pkg.isDiscontinued ? true : null,
      replacedBy: pkg.replacedBy,
      latest: latest.toApiVersionInfo(),
      versions: packageVersions.map((pv) => pv.toApiVersionInfo()).toList(),
    );
  }

  /// Returns the known versions of [package] (via [listVersions]),
  /// getting it from cache if available.
  ///
  /// The data is converted to JSON and UTF-8 (and stored like that in the cache).
  Future<List<int>> listVersionsCachedBytes(String package) async {
    final body = await cache.packageDataGz(package).get(() async {
      final data = await listVersions(package);
      final raw = jsonUtf8Encoder.convert(data.toJson());
      return gzip.encode(raw);
    });
    return body!;
  }

  /// Returns the known versions of [package] (via [listVersions]),
  /// getting it from the cache if available.
  ///
  ///  The available versions are sorted by their semantic version number (ascending).
  Future<api.PackageData> listVersionsCached(String package) async {
    final data = await listVersionsCachedBytes(package);
    return api.PackageData.fromJson(
        utf8JsonDecoder.convert(gzip.decode(data)) as Map<String, dynamic>);
  }

  /// Lookup and return the API's version info object.
  ///
  /// Throws [NotFoundException] when the version is missing.
  Future<api.VersionInfo> lookupVersion(String package, String version) async {
    checkPackageVersionParams(package, version);
    final canonicalVersion = canonicalizeVersion(version);
    InvalidInputException.checkSemanticVersion(canonicalVersion);

    final packageVersionKey = db.emptyKey
        .append(Package, id: package)
        .append(PackageVersion, id: canonicalVersion);

    if (!await isPackageVisible(package)) {
      throw NotFoundException.resource('package "$package"');
    }
    final pv = await db.lookupOrNull<PackageVersion>(packageVersionKey);
    if (pv == null) {
      throw NotFoundException.resource('version "$version"');
    }

    return pv.toApiVersionInfo();
  }

  Future<api.UploadInfo> startUpload(Uri redirectUrl) async {
    final restriction = await getUploadRestrictionStatus();
    if (restriction == UploadRestrictionStatus.noUploads) {
      throw PackageRejectedException.uploadRestricted();
    }
    _logger.info('Starting async upload.');
    // NOTE: We use a authenticated user scope here to ensure the uploading
    // user is authenticated. But we're not validating anything at this point
    // because we don't even know which package or version is going to be
    // uploaded.
    final user = await requireAuthenticatedUser(source: AuthSource.client);
    _logger.info('User: ${user.email}.');

    final guid = createUuid();
    final String object = tmpObjectName(guid);
    final String bucket = _incomingBucket.bucketName;
    final Duration lifetime = const Duration(minutes: 10);

    final url = redirectUrl.resolve('?upload_id=$guid');

    _logger
        .info('Redirecting pub client to google cloud storage (uuid: $guid)');
    return uploadSigner.buildUpload(
      bucket,
      object,
      lifetime,
      successRedirectUrl: '$url',
    );
  }

  /// Finishes the upload of a package.
  Future<PackageVersion> publishUploadedBlob(String guid) async {
    final restriction = await getUploadRestrictionStatus();
    if (restriction == UploadRestrictionStatus.noUploads) {
      throw PackageRejectedException.uploadRestricted();
    }
    final agent = await requireAuthenticatedAgent(source: AuthSource.client);
    _logger.info('Finishing async upload (uuid: $guid)');
    _logger.info('Reading tarball from cloud storage.');

    return await withTempDirectory((Directory dir) async {
      final filename = '${dir.absolute.path}/tarball.tar.gz';
      final info = await _incomingBucket.tryInfo(tmpObjectName(guid));
      if (info?.length == null) {
        throw PackageRejectedException.archiveEmpty();
      }
      if (info!.length > UploadSignerService.maxUploadSize) {
        throw PackageRejectedException.archiveTooLarge(
            UploadSignerService.maxUploadSize);
      }
      await _saveTarballToFS(
          _incomingBucket.read(tmpObjectName(guid)), filename);
      _logger.info('Examining tarball content ($guid).');
      final sw = Stopwatch()..start();
      final file = File(filename);
      final fileBytes = await file.readAsBytes();
      final sha256Hash = sha256.convert(fileBytes).bytes;
      final archive = await summarizePackageArchive(
        filename,
        maxContentLength: maxAssetContentLength,
        maxArchiveSize: UploadSignerService.maxUploadSize,
        published: clock.now().toUtc(),
      );
      _logger.info('Package archive scanned in ${sw.elapsed}.');
      if (archive.hasIssues) {
        throw PackageRejectedException(archive.issues.first.message);
      }

      final pubspec = Pubspec.fromYaml(archive.pubspecContent!);
      await _verifyPackageName(
        name: pubspec.name,
        agent: agent,
      );

      // Check if new packages are allowed to be uploaded.
      if (restriction == UploadRestrictionStatus.onlyUpdates &&
          !(await isPackageVisible(pubspec.name))) {
        throw PackageRejectedException.uploadRestricted();
      }

      // Check version format.
      final versionString = canonicalizeVersion(pubspec.nonCanonicalVersion);
      if (versionString == null) {
        throw InvalidInputException.canonicalizeVersionError(
            pubspec.nonCanonicalVersion);
      }

      // Check canonical archive.
      final canonicalArchivePath =
          tarballObjectName(pubspec.name, versionString);
      final canonicalArchiveInfo =
          await _canonicalBucket.tryInfo(canonicalArchivePath);
      if (canonicalArchiveInfo != null) {
        // Actually fetch the archive bytes and do full comparison.
        final objectBytes =
            await _canonicalBucket.readAsBytes(canonicalArchivePath);
        if (!fileBytes.byteToByteEquals(objectBytes)) {
          throw PackageRejectedException.versionExists(
              pubspec.name, versionString);
        }
      }

      sw.reset();
      final entities = await _createUploadEntities(db, agent, archive,
          sha256Hash: sha256Hash);
      final version = await _performTarballUpload(
        entities: entities,
        agent: agent,
        archive: archive,
        guid: guid,
        hasCanonicalArchiveObject: canonicalArchiveInfo != null,
      );
      _logger.info('Tarball uploaded in ${sw.elapsed}.');
      _logger.info('Removing temporary object $guid.');

      sw.reset();
      await _incomingBucket.delete(tmpObjectName(guid));
      _logger.info('Temporary object removed in ${sw.elapsed}.');
      return version;
    });
  }

  /// Verify the package name defined in the newly uploaded archive file,
  /// and throw [PackageRejectedException] if it is not accepted.
  /// Some reasons to reject a name:
  /// - it is closely related to another package name,
  /// - it is already being blocked,
  /// - it is reserved for future internal use, but the current user is
  ///   not authorized to claim such package names.
  Future<void> _verifyPackageName({
    required String name,
    required AuthenticatedAgent agent,
  }) async {
    final conflictingName = await nameTracker.accept(name);
    if (conflictingName != null) {
      final visible = await isPackageVisible(conflictingName);
      if (visible) {
        throw PackageRejectedException.similarToActive(name, conflictingName,
            urls.pkgPageUrl(conflictingName, includeHost: true));
      } else {
        throw PackageRejectedException.similarToModerated(
            name, conflictingName);
      }
    }
    PackageRejectedException.check(conflictingName == null,
        'Package name is too similar to another active or moderated package: `$conflictingName`.');

    // Apply name verification for new packages.
    final isCurrentlyVisible = await isPackageVisible(name);
    if (!isCurrentlyVisible) {
      final newNameIssues = validateNewPackageName(name).toList();
      if (newNameIssues.isNotEmpty) {
        throw PackageRejectedException(newNameIssues.first.message);
      }

      // reserved package names for the Dart team
      if (matchesReservedPackageName(name)) {
        if (agent is! AuthenticatedUser ||
            !agent.user.email!.endsWith('@google.com')) {
          throw PackageRejectedException.nameReserved(name);
        }
      }
    }
  }

  /// Makes a temporary object a new tarball.
  Future<void> _uploadViaTempObject(
    String guid,
    String package,
    String version,
  ) async {
    final object = tarballObjectName(package, version);

    // Copy the temporary object to it's destination place.
    await _storage.copyObject(
      _incomingBucket.absoluteObjectName(tmpObjectName(guid)),
      _bucket.absoluteObjectName(object),
    );

    // Change the ACL to include a `public-read` entry.
    final ObjectInfo info = await _bucket.info(object);
    final publicRead = AclEntry(AllUsersScope(), AclPermission.READ);
    final acl = Acl(List.from(info.metadata.acl!.entries)..add(publicRead));
    await _bucket.updateMetadata(object, info.metadata.replace(acl: acl));
  }

  Future<PackageVersion> _performTarballUpload({
    required _UploadEntities entities,
    required AuthenticatedAgent agent,
    required PackageSummary archive,
    required String guid,
    required bool hasCanonicalArchiveObject,
  }) async {
    final sw = Stopwatch()..start();
    final newVersion = entities.packageVersion;
    final currentDartSdk = await getDartSdkVersion();

    Package? package;
    String? prevLatestStableVersion;
    String? prevLatestPrereleaseVersion;

    // Add the new package to the repository by storing the tarball and
    // inserting metadata to datastore (which happens atomically).
    final pv = await withRetryTransaction(db, (tx) async {
      _logger.info('Starting datastore transaction.');

      final tuple = (await tx.lookup([newVersion.key, newVersion.packageKey!]));
      final version = tuple[0] as PackageVersion?;
      package = tuple[1] as Package?;
      prevLatestStableVersion = package?.latestVersion;
      prevLatestPrereleaseVersion = package?.latestPrereleaseVersion;

      // If the version already exists, we fail.
      if (version != null) {
        _logger.info('Version ${version.version} of package '
            '${version.package} already exists, rolling transaction back.');
        throw PackageRejectedException.versionExists(
            version.package, version.version!);
      }

      // If the package does not exist, then we create a new package.
      if (package == null) {
        _logger.info('New package uploaded. [new-package-uploaded]');
        package = Package.fromVersion(newVersion);
      } else {
        final isAdmin = await packageBackend.isPackageAdmin(
          package!,
          agent is AuthenticatedUser ? agent.user.userId : null,
          agent: agent,
        );
        if (!isAdmin) {
          _logger.info('User ${agent.agentId} (${agent.displayId}) '
              'is not an uploader for package ${package!.name}, rolling transaction back.');
          throw AuthorizationException.userCannotUploadNewVersion(
              agent.displayId, package!.name!);
        }
      }

      if (package!.isNotVisible) {
        throw PackageRejectedException.isBlocked();
      }

      if (package!.versionCount >= maxVersionsPerPackage) {
        throw PackageRejectedException.maxVersionCountReached(
            newVersion.package, maxVersionsPerPackage);
      }

      if (package!.deletedVersions != null &&
          package!.deletedVersions!.contains(newVersion.version!)) {
        throw PackageRejectedException.versionDeleted(
            package!.name!, newVersion.version!);
      }

      // Store the publisher of the package at the time of the upload.
      newVersion.publisherId = package!.publisherId;

      // Keep the latest version in the package object up-to-date.
      package!.updateVersion(newVersion,
          dartSdkVersion: currentDartSdk.semanticVersion);
      package!.updated = clock.now().toUtc();
      package!.versionCount++;

      _logger.info(
        'Trying to upload tarball for ${package!.name} version ${newVersion.version} to cloud storage.',
      );
      if (!hasCanonicalArchiveObject) {
        // Copy archive to canonical bucket.
        await _storage.copyObject(
          _incomingBucket.absoluteObjectName(tmpObjectName(guid)),
          _canonicalBucket.absoluteObjectName(
              tarballObjectName(newVersion.package, newVersion.version!)),
        );
      }
      await _uploadViaTempObject(guid, package!.name!, newVersion.version!);
      await _storage.copyObject(
        _incomingBucket.absoluteObjectName(tmpObjectName(guid)),
        _publicBucket.absoluteObjectName(
            tarballObjectName(newVersion.package, newVersion.version!)),
      );

      final inserts = <Model>[
        package!,
        newVersion,
        entities.packageVersionInfo,
        ...entities.assets,
        AuditLogRecord.packagePublished(
          uploader: agent,
          package: newVersion.package,
          version: newVersion.version!,
          created: newVersion.created!,
          publisherId: package!.publisherId,
        ),
      ];

      _logger.info('Trying to commit datastore changes.');
      tx.queueMutations(inserts: inserts);
      return newVersion;
    });
    _logger.info('Upload successful. [package-uploaded]');
    _logger.info('Upload transaction compelted in ${sw.elapsed}.');
    sw.reset();

    _logger.info('Invalidating cache for package ${newVersion.package}.');
    await purgePackageCache(newVersion.package);

    try {
      final uploaderEmails = package!.publisherId == null
          ? await accountBackend.getEmailsOfUserIds(package!.uploaders!)
          : await publisherBackend.getAdminMemberEmails(package!.publisherId!);

      // Notify uploaders via email that a new version has been published.
      final email = emailSender.sendMessage(createPackageUploadedEmail(
        packageName: newVersion.package,
        packageVersion: newVersion.version!,
        displayId: agent.displayId,
        authorizedUploaders:
            uploaderEmails.map((email) => EmailAddress(null, email)).toList(),
      ));

      final latestVersionChanged = prevLatestStableVersion != null &&
          package!.latestVersion != prevLatestStableVersion;
      final latestPrereleaseVersionChanged =
          prevLatestPrereleaseVersion != null &&
              package!.latestPrereleaseVersion != prevLatestPrereleaseVersion;
      // Let's not block the upload response on these. In case of a timeout, the
      // underlying operations still go ahead, but the `Future.wait` call below
      // is not blocked on it.
      await Future.wait([
        email,
        // Trigger analysis and dartdoc generation. Dependent packages can be left
        // out here, because the dependency graph's background polling will pick up
        // the new upload, and will trigger analysis for the dependent packages.
        jobBackend.triggerAnalysis(newVersion.package, newVersion.version),
        jobBackend.triggerDartdoc(newVersion.package, newVersion.version),
        // Trigger a new doc generation for the previous latest stable version
        // in order to update the dartdoc entry and the canonical-urls.
        if (latestVersionChanged)
          jobBackend.triggerDartdoc(newVersion.package, prevLatestStableVersion,
              shouldProcess: true),
        // Reset the priority of the previous pre-release version.
        if (latestPrereleaseVersionChanged)
          jobBackend.triggerDartdoc(
              newVersion.package, prevLatestPrereleaseVersion,
              shouldProcess: false),
      ]).timeout(Duration(seconds: 10));
    } catch (e, st) {
      final v = newVersion.qualifiedVersionKey;
      _logger.severe('Error post-processing package upload $v', e, st);
    }
    _logger.info('Post-upload tasks completed in ${sw.elapsed}.');
    return pv;
  }

  /// Read the archive bytes from the canonical bucket.
  Future<List<int>> readArchiveBytes(String package, String version) async {
    final objectName = tarballObjectName(package, version);
    return await _canonicalBucket.readAsBytes(objectName);
  }

  // Uploaders support.

  Future<account_api.InviteStatus> inviteUploader(
    String packageName,
    api.InviteUploaderRequest invite, {
    AuthSource? authSource,
  }) async {
    authSource ??= AuthSource.website;
    InvalidInputException.checkNotNull(invite.email, 'email');
    final uploaderEmail = invite.email.toLowerCase();
    final user = await requireAuthenticatedUser(source: authSource);
    final packageKey = db.emptyKey.append(Package, id: packageName);
    final package = await db.lookupOrNull<Package>(packageKey);

    await _validatePackageUploader(packageName, package, user.userId);
    // Don't send invites for publisher-owned packages.
    if (package!.publisherId != null) {
      throw OperationForbiddenException.publisherOwnedPackageNoUploader(
          packageName, package.publisherId!);
    }

    InvalidInputException.check(
        isValidEmail(uploaderEmail), 'Not a valid email: `$uploaderEmail`.');

    final uploaderUsers =
        await accountBackend.lookupUsersById(package.uploaders!);
    final isNotUploaderYet =
        !uploaderUsers.any((u) => u!.email == uploaderEmail);
    InvalidInputException.check(
        isNotUploaderYet, '`$uploaderEmail` is already an uploader.');

    final status = await consentBackend.invitePackageUploader(
      activeUser: user,
      packageName: packageName,
      uploaderEmail: uploaderEmail,
    );

    return account_api.InviteStatus(
      emailSent: status.emailSent,
      nextNotification: status.nextNotification,
    );
  }

  Future<void> confirmUploader(
    String fromUserId,
    String fromUserEmail,
    String packageName,
    User uploader, {
    required bool isFromAdminUser,
  }) async {
    await withRetryTransaction(db, (tx) async {
      final packageKey = db.emptyKey.append(Package, id: packageName);
      final package = (await tx.lookup([packageKey])).first as Package;

      await _validatePackageUploader(
        packageName,
        package,
        fromUserId,
        isFromAdminUser: isFromAdminUser,
      );
      if (package.containsUploader(uploader.userId)) {
        // The requested uploaderEmail is already part of the uploaders.
        return;
      }

      // Add [uploaderEmail] to uploaders and commit.
      package.addUploader(uploader.userId);
      package.updated = clock.now().toUtc();

      tx.insert(package);
      tx.insert(AuditLogRecord.uploaderInviteAccepted(
        user: uploader,
        package: packageName,
      ));
    });
    await purgePackageCache(packageName);
  }

  Future<void> _validatePackageUploader(
    String packageName,
    Package? package,
    String userId, {
    bool isFromAdminUser = false,
  }) async {
    // Fail if package doesn't exist.
    if (package == null) {
      throw NotFoundException.resource(packageName);
    }

    if (isFromAdminUser) {
      // Fail if calling user doesn't have admin permissions anymore.
      final user = await accountBackend.lookupUserById(userId);
      if (user == null) {
        throw AuthorizationException.userCannotChangeUploaders(package.name!);
      }
      final isAuthorizedAdmin = await adminBackend.verifyAdminPermission(
          user, AdminPermission.managePackageOwnership);
      if (isAuthorizedAdmin) {
        return;
      } else {
        throw AuthorizationException.userCannotChangeUploaders(package.name!);
      }
    }

    // Fail if calling user doesn't have permission to change uploaders.
    if (!await packageBackend.isPackageAdmin(package, userId)) {
      throw AuthorizationException.userCannotChangeUploaders(package.name!);
    }
  }

  Future<api.SuccessMessage> removeUploader(
    String packageName,
    String uploaderEmail,
  ) async {
    uploaderEmail = uploaderEmail.toLowerCase();
    final user = await requireAuthenticatedUser();
    await withRetryTransaction(db, (tx) async {
      final packageKey = db.emptyKey.append(Package, id: packageName);
      final package = await tx.lookupOrNull<Package>(packageKey);
      if (package == null) {
        throw NotFoundException.resource('package: $packageName');
      }

      await _validatePackageUploader(packageName, package, user.userId);

      // Fail if the uploader we want to remove does not exist.
      final uploaderUsers =
          await accountBackend.lookupUsersById(package.uploaders!);
      final uploadersWithEmail = <User>[];
      for (final u in uploaderUsers) {
        final email = await accountBackend.getEmailOfUserId(u!.userId);
        if (email == uploaderEmail) uploadersWithEmail.add(u);
      }
      if (uploadersWithEmail.isEmpty) {
        throw NotFoundException.resource('uploader: $uploaderEmail');
      }
      if (uploadersWithEmail.length > 1) {
        throw NotAcceptableException(
            'Multiple uploaders with email: $uploaderEmail');
      }
      final uploader = uploadersWithEmail.single;

      // We cannot have 0 uploaders, if we would remove the last one, we
      // fail with an error.
      if (package.uploaderCount <= 1) {
        throw OperationForbiddenException.lastUploaderRemoveError();
      }

      // At the moment we don't validate whether the other email addresses
      // are able to authenticate. To prevent accidentally losing the control
      // of a package, we don't allow self-removal.
      if (user.email == uploader.email || user.userId == uploader.userId) {
        throw OperationForbiddenException.selfRemovalNotAllowed();
      }

      // Remove the uploader from the list.
      package.removeUploader(uploader.userId);
      package.updated = clock.now().toUtc();

      tx.insert(package);
      tx.insert(AuditLogRecord.uploaderRemoved(
        activeUser: user,
        package: packageName,
        uploaderUser: uploader,
      ));
    });
    await purgePackageCache(packageName);
    return api.SuccessMessage(
        success: api.Message(
            message:
                '$uploaderEmail has been removed as an uploader for this package.'));
  }

  Future<UploadRestrictionStatus> getUploadRestrictionStatus() async {
    final value =
        await secretBackend.getCachedValue(SecretKey.uploadRestriction) ?? '';
    switch (value) {
      case 'no-uploads':
        return UploadRestrictionStatus.noUploads;
      case 'only-updates':
        return UploadRestrictionStatus.onlyUpdates;
      case '':
      case '-':
      case 'no-restriction':
        return UploadRestrictionStatus.noRestriction;
    }
    // safe fallback on enabling uploads
    _logger.warning('Unknown upload restriction status: $value');
    return UploadRestrictionStatus.noRestriction;
  }

  /// Deletes the tarball of a [package] in the given [version] permanently.
  Future<void> removePackageTarball(String package, String version) async {
    final object = tarballObjectName(package, version);
    await deleteFromBucket(_bucket, object);
    await deleteFromBucket(_publicBucket, object);
    await deleteFromBucket(_canonicalBucket, object);
  }

  /// Gets the file info of a [package] in the given [version].
  Future<ObjectInfo?> packageTarballinfo(String package, String version) async {
    return await _publicBucket.tryInfo(tarballObjectName(package, version));
  }
}

extension PackageVersionExt on PackageVersion {
  api.VersionInfo toApiVersionInfo() {
    final hasSha256 = this.sha256 != null && this.sha256!.isNotEmpty;
    final archiveSha256 = hasSha256 ? hex.encode(this.sha256!) : null;
    return api.VersionInfo(
      version: version!,
      retracted: isRetracted ? true : null,
      pubspec: pubspec!.asJson,
      archiveUrl: urls.pkgArchiveDownloadUrl(
        package,
        version!,

        /// We should use the primary API URI here, because the generated URLs may
        /// end up in multiple cache, and it is critical that we always serve the
        /// content with the proper cached URLs.
        baseUri: activeConfiguration.primaryApiUri,
      ),
      archiveSha256: archiveSha256,
      published: created,
    );
  }
}

enum UploadRestrictionStatus {
  /// Publication of new packages and new versions of existing packages is allowed.
  noRestriction,

  /// Publication of new packages is **not** allowed, new versions of existing packages is allowed.
  onlyUpdates,

  /// Publication of packages is **not** allowed.
  noUploads,
}

/// Loads [package], returns its [Package] instance, and also checks if
/// [userId] is an admin of the package.
///
/// Throws AuthenticationException if the user is provided.
/// Throws AuthorizationException if the user is not an admin for the package.
Future<Package> requirePackageAdmin(String package, String? userId) async {
  if (userId == null) {
    throw AuthenticationException.authenticationRequired();
  }
  final p = await packageBackend.lookupPackage(package);
  if (p == null) {
    throw NotFoundException.resource('package "$package"');
  }
  await packageBackend.checkPackageAdmin(p, userId);
  return p;
}

api.PackagePublisherInfo _asPackagePublisherInfo(Package p) =>
    api.PackagePublisherInfo(publisherId: p.publisherId);

/// Purge [cache] entries for given [package] and also global page caches.
Future<void> purgePackageCache(String package) async {
  await Future.wait([
    cache.packageVisible(package).purge(),
    cache.packageData(package).purge(),
    cache.packageDataGz(package).purge(),
    cache.packageLatestVersion(package).purge(),
    cache.packageView(package).purge(),
    cache.uiPackagePage(package, null).purge(),
    cache.uiPackageChangelog(package, null).purge(),
    cache.uiPackageExample(package, null).purge(),
    cache.uiPackageInstall(package, null).purge(),
    cache.uiPackageScore(package, null).purge(),
    cache.uiPackageVersions(package).purge(),
    cache.uiIndexPage().purge(),
  ]);
}

/// The status of an invite after being created or updated.
class InviteStatus {
  final String? urlNonce;
  final DateTime? nextNotification;

  InviteStatus({this.urlNonce, this.nextNotification});

  bool get isActive => urlNonce != null;

  bool get isDelayed => nextNotification != null;
}

/// Reads a tarball from a byte stream.
///
/// Completes with an error if the incoming stream has an error or if the size
/// exceeds [UploadSignerService.maxUploadSize].
Future _saveTarballToFS(Stream<List<int>> data, String filename) async {
  final sw = Stopwatch()..start();
  final targetFile = File(filename);
  try {
    int receivedBytes = 0;
    final stream = data.transform<List<int>>(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          receivedBytes += chunk.length;
          if (receivedBytes <= UploadSignerService.maxUploadSize) {
            sink.add(chunk);
          } else {
            sink.addError(PackageRejectedException.archiveTooLarge(
                UploadSignerService.maxUploadSize));
          }
        },
      ),
    );
    await stream.pipe(targetFile.openWrite());
  } catch (e, st) {
    _logger.warning('An error occured while streaming tarball to FS.', e, st);
    rethrow;
  }
  _logger.info('Finished streaming tarball to FS (elapsed: ${sw.elapsed}).');
}

class _UploadEntities {
  final PackageVersion packageVersion;
  final PackageVersionInfo packageVersionInfo;
  final List<PackageVersionAsset> assets;

  _UploadEntities(
    this.packageVersion,
    this.packageVersionInfo,
    this.assets,
  );
}

class DerivedPackageVersionEntities {
  final PackageVersionInfo packageVersionInfo;
  final List<PackageVersionAsset> assets;

  DerivedPackageVersionEntities(
    this.packageVersionInfo,
    this.assets,
  );
}

/// Creates entities from [archive] summary.
Future<_UploadEntities> _createUploadEntities(
  DatastoreDB db,
  AuthenticatedAgent agent,
  PackageSummary archive, {
  required List<int> sha256Hash,
}) async {
  final pubspec = Pubspec.fromYaml(archive.pubspecContent!);
  final packageKey = db.emptyKey.append(Package, id: pubspec.name);
  final versionString = canonicalizeVersion(pubspec.nonCanonicalVersion);

  final version = PackageVersion()
    ..id = versionString
    ..parentKey = packageKey
    ..version = versionString
    ..packageKey = packageKey
    ..created = clock.now().toUtc()
    ..pubspec = pubspec
    ..libraries = archive.libraries
    ..uploader = agent.agentId
    ..sha256 = sha256Hash
    ..isRetracted = false;

  final derived = derivePackageVersionEntities(
    archive: archive,
    versionCreated: version.created!,
  );

  // TODO: verify if assets sizes are within the transaction limit (10 MB)
  return _UploadEntities(version, derived.packageVersionInfo, derived.assets);
}

/// Creates new Datastore entities from the actual extraction of package [archive].
DerivedPackageVersionEntities derivePackageVersionEntities({
  required PackageSummary archive,
  required DateTime versionCreated,
}) {
  final pubspec = Pubspec.fromYaml(archive.pubspecContent!);
  final key = QualifiedVersionKey(
      package: pubspec.name, version: pubspec.canonicalVersion);

  String? capContent(String? text) {
    if (text == null) return text;
    if (text.length < maxAssetContentLength) return text;
    return text.substring(0, maxAssetContentLength);
  }

  final assets = <PackageVersionAsset>[
    PackageVersionAsset.init(
      package: key.package,
      version: key.version,
      kind: AssetKind.pubspec,
      versionCreated: versionCreated,
      path: 'pubspec.yaml',
      textContent: capContent(archive.pubspecContent),
    ),
    if (archive.readmePath != null)
      PackageVersionAsset.init(
        package: key.package,
        version: key.version,
        kind: AssetKind.readme,
        versionCreated: versionCreated,
        path: archive.readmePath,
        textContent: capContent(archive.readmeContent),
      ),
    if (archive.changelogPath != null)
      PackageVersionAsset.init(
        package: key.package,
        version: key.version,
        kind: AssetKind.changelog,
        versionCreated: versionCreated,
        path: archive.changelogPath,
        textContent: capContent(archive.changelogContent),
      ),
    if (archive.examplePath != null)
      PackageVersionAsset.init(
        package: key.package,
        version: key.version,
        kind: AssetKind.example,
        versionCreated: versionCreated,
        path: archive.examplePath,
        textContent: capContent(archive.exampleContent),
      ),
    if (archive.licensePath != null)
      PackageVersionAsset.init(
        package: key.package,
        version: key.version,
        kind: AssetKind.license,
        versionCreated: versionCreated,
        path: archive.licensePath,
        textContent: capContent(archive.licenseContent),
      ),
  ];

  final versionInfo = PackageVersionInfo()
    ..initFromKey(key)
    ..versionCreated = versionCreated
    ..updated = clock.now().toUtc()
    ..libraries = archive.libraries
    ..libraryCount = archive.libraries!.length
    ..assets = assets.map((a) => a.kind!).toList()
    ..assetCount = assets.length;

  return DerivedPackageVersionEntities(versionInfo, assets);
}

/// The GCS object name of a tarball object - excluding leading '/'.
@visibleForTesting
String tarballObjectName(String package, String version) =>
    'packages/$package-$version.tar.gz';

/// The GCS object name of an temporary object [guid] - excluding leading '/'.
@visibleForTesting
String tmpObjectName(String guid) => 'tmp/$guid';

/// Verify that the [package] and the optional [version] parameter looks as acceptable input.
void checkPackageVersionParams(String package, [String? version]) {
  InvalidInputException.checkPackageName(package);
  if (version != null) {
    InvalidInputException.check(version.trim() == version, 'Invalid version.');
    InvalidInputException.checkStringLength(version, 'version',
        minimum: 1, maximum: 64);
    if (version != 'latest') {
      InvalidInputException.checkSemanticVersion(version);
    }
  }
}
