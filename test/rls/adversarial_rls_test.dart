import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const supabaseUrl = 'https://dyfrknwejqwilstcoytt.supabase.co';
  const supabaseAnonKey = 'sb_publishable_jBV_X6q8QXB4gIRSeny0GA_YnMwkNcT';

  group('Mandatory Adversarial RLS Multi-Tenant Test Suite', () {
    late SupabaseClient clientA;
    late SupabaseClient clientB;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final emailA = 'dr.alice.test.$timestamp@gmail.com';
    final emailB = 'dr.bob.test.$timestamp@gmail.com';
    const password = 'SecurePassword123!';

    String? clinicAId;
    String? doctorAId;
    String? clinicBId;
    String? doctorBId;

    setUpAll(() async {
      // Initialize independent Supabase clients for Doctor A and Doctor B with implicit flow for pure Dart test environment
      clientA = SupabaseClient(
        supabaseUrl,
        supabaseAnonKey,
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      );
      clientB = SupabaseClient(
        supabaseUrl,
        supabaseAnonKey,
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      );

      // 1. Sign up Doctor A
      final authRespA = await clientA.auth.signUp(
        email: emailA,
        password: password,
      );
      expect(
        authRespA.user,
        isNotNull,
        reason: 'Doctor A auth creation should succeed',
      );

      // Call atomic RPC to provision Clinic A and Doctor A
      final rpcRespA = await clientA.rpc(
        'create_clinic_and_doctor',
        params: {
          'p_clinic_name': 'Clinic Alpha $timestamp',
          'p_clinic_address': '101 Healthcare Way, Delhi',
          'p_clinic_contact': '+91-11-20000001',
          'p_doctor_name': 'Dr. Alice Sharma',
          'p_qualifications': 'MBBS, MD',
          'p_registration_number': 'DMC-10001',
          'p_doctor_contact': '+91-9876543210',
        },
      );
      clinicAId = rpcRespA['clinic_id'] as String?;
      doctorAId = rpcRespA['doctor_id'] as String?;
      expect(clinicAId, isNotNull);
      expect(doctorAId, isNotNull);

      // 2. Sign up Doctor B
      final authRespB = await clientB.auth.signUp(
        email: emailB,
        password: password,
      );
      expect(
        authRespB.user,
        isNotNull,
        reason: 'Doctor B auth creation should succeed',
      );

      // Call atomic RPC to provision Clinic B and Doctor B
      final rpcRespB = await clientB.rpc(
        'create_clinic_and_doctor',
        params: {
          'p_clinic_name': 'Clinic Beta $timestamp',
          'p_clinic_address': '202 Medical Avenue, Mumbai',
          'p_clinic_contact': '+91-22-30000002',
          'p_doctor_name': 'Dr. Bob Patel',
          'p_qualifications': 'MBBS, MS',
          'p_registration_number': 'MMC-20002',
          'p_doctor_contact': '+91-9876543211',
        },
      );
      clinicBId = rpcRespB['clinic_id'] as String?;
      doctorBId = rpcRespB['doctor_id'] as String?;
      expect(clinicBId, isNotNull);
      expect(doctorBId, isNotNull);

      // Verify each doctor can read their own clinic
      final ownClinicA = await clientA
          .from('clinics')
          .select()
          .eq('id', clinicAId!)
          .single();
      expect(ownClinicA['name'], contains('Clinic Alpha'));

      final ownClinicB = await clientB
          .from('clinics')
          .select()
          .eq('id', clinicBId!)
          .single();
      expect(ownClinicB['name'], contains('Clinic Beta'));
    });

    test(
      'ADVERSARIAL 1: Direct client INSERT into clinics is denied by RLS',
      () async {
        // Correction 2 requirement: Standing client INSERT policy removed.
        expect(
          () async => await clientA.from('clinics').insert({
            'name': 'Malicious Direct Injected Clinic',
            'address': 'Nowhere',
          }),
          throwsA(isA<PostgrestException>()),
          reason: 'Direct client INSERT on clinics must be denied by default under RLS',
        );
      },
    );

    test('ADVERSARIAL 2: Secondary call to create_clinic_and_doctor RPC is rejected', () async {
      // Requirement: Already-onboarded doctor cannot create a second clinic
      expect(
        () async => await clientA.rpc(
          'create_clinic_and_doctor',
          params: {
            'p_clinic_name': 'Duplicate Clinic Attempt',
            'p_clinic_address': '123 Fake St',
            'p_clinic_contact': '000',
            'p_doctor_name': 'Dr. Alice Sharma',
            'p_qualifications': 'MBBS',
            'p_registration_number': 'DMC-10001',
            'p_doctor_contact': '000',
          },
        ),
        throwsA(
          predicate(
            (e) =>
                e is PostgrestException &&
                e.message.contains(
                  'Doctor is already associated with a clinic',
                ),
          ),
        ),
        reason: 'A doctor already associated with a clinic cannot invoke onboarding RPC again',
      );
    });

    test('ADVERSARIAL 3: Anti-Tenant-Hopping - Updating clinic_id on doctors is denied by column grant', () async {
      // Correction 3 requirement: Column grant revokes blanket UPDATE and restricts to safe columns.
      expect(
        () async => await clientA
            .from('doctors')
            .update({'clinic_id': clinicBId})
            .eq('id', doctorAId!),
        throwsA(
          predicate(
            (e) =>
                e is PostgrestException &&
                (e.message.toLowerCase().contains('permission denied') ||
                    e.message.toLowerCase().contains('clinic_id')),
          ),
        ),
        reason: 'Reassigning clinic_id on doctors row must be blocked by column privilege revocation',
      );
    });

    test('ADVERSARIAL 4: Updating auth_user_id on doctors is denied by column grant', () async {
      // Correction 3 requirement: Column grant prevents auth reassignment
      final doctorBAuthId = clientB.auth.currentUser!.id;
      expect(
        () async => await clientA
            .from('doctors')
            .update({'auth_user_id': doctorBAuthId})
            .eq('id', doctorAId!),
        throwsA(
          predicate(
            (e) =>
                e is PostgrestException &&
                (e.message.toLowerCase().contains('permission denied') ||
                    e.message.toLowerCase().contains('auth_user_id')),
          ),
        ),
        reason: 'Reassigning auth_user_id on doctors row must be blocked by column privilege revocation',
      );
    });

    test('ADVERSARIAL 5: Cross-Tenant Isolation - Doctor A cannot SELECT Doctor B clinic', () async {
      // RLS policy: USING (id = public.get_auth_clinic_id())
      final result = await clientA
          .from('clinics')
          .select()
          .eq('id', clinicBId!);
      expect(
        result,
        isEmpty,
        reason: 'Doctor A must receive empty set when querying Doctor B clinic',
      );
    });

    test('ADVERSARIAL 6: Cross-Tenant Isolation - Doctor A cannot UPDATE Doctor B clinic', () async {
      // RLS policy: USING/CHECK (id = public.get_auth_clinic_id())
      final result = await clientA
          .from('clinics')
          .update({'name': 'HACKED CLINIC NAME'})
          .eq('id', clinicBId!)
          .select();
      expect(
        result,
        isEmpty,
        reason: 'Doctor A mutation on Doctor B clinic must affect 0 rows',
      );

      // Verify Clinic B name is untouched in actual DB
      final untouchedClinicB = await clientB
          .from('clinics')
          .select()
          .eq('id', clinicBId!)
          .single();
      expect(untouchedClinicB['name'], contains('Clinic Beta'));
    });

    test('ADVERSARIAL 7: Cross-Tenant Isolation - Doctor A cannot SELECT Doctor B profile', () async {
      // RLS policy: USING (clinic_id = public.get_auth_clinic_id() OR auth_user_id = auth.uid())
      final result = await clientA
          .from('doctors')
          .select()
          .eq('id', doctorBId!);
      expect(
        result,
        isEmpty,
        reason:
            'Doctor A must receive empty set when querying Doctor B profile',
      );
    });

    test('ADVERSARIAL 8: Cross-Tenant Isolation - Doctor A cannot UPDATE Doctor B profile', () async {
      // RLS policy: USING (auth.uid() = auth_user_id)
      final result = await clientA
          .from('doctors')
          .update({'full_name': 'HACKED DOCTOR NAME'})
          .eq('id', doctorBId!)
          .select();
      expect(
        result,
        isEmpty,
        reason: 'Doctor A mutation on Doctor B profile must affect 0 rows',
      );

      // Verify Doctor B name is untouched in actual DB
      final untouchedDoctorB = await clientB
          .from('doctors')
          .select()
          .eq('id', doctorBId!)
          .single();
      expect(untouchedDoctorB['full_name'], equals('Dr. Bob Patel'));
    });

    test('ADVERSARIAL 9: Transaction Atomicity - Failure mid-onboarding leaves NO orphaned clinic', () async {
      // Provision fresh auth user C
      final clientC = SupabaseClient(
        supabaseUrl,
        supabaseAnonKey,
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      );
      final emailC = 'dr.charlie.test.$timestamp@gmail.com';
      final authRespC = await clientC.auth.signUp(
        email: emailC,
        password: password,
      );
      expect(authRespC.user, isNotNull);

      // Force failure by passing empty doctor name
      expect(
        () async => await clientC.rpc(
          'create_clinic_and_doctor',
          params: {
            'p_clinic_name': 'Orphan Clinic Test $timestamp',
            'p_clinic_address': 'Some Address',
            'p_clinic_contact': '111',
            'p_doctor_name': '', // Deliberate failure trigger
            'p_qualifications': 'MBBS',
            'p_registration_number': '123',
            'p_doctor_contact': '111',
          },
        ),
        throwsA(
          predicate(
            (e) =>
                e is PostgrestException &&
                e.message.contains('Doctor name is required'),
          ),
        ),
      );

      // Verify no orphaned clinic with this name was committed
      // (Query via clientA and clientB to confirm it does not exist)
      final searchA = await clientA
          .from('clinics')
          .select()
          .eq('name', 'Orphan Clinic Test $timestamp');
      expect(searchA, isEmpty);

      final searchB = await clientB
          .from('clinics')
          .select()
          .eq('name', 'Orphan Clinic Test $timestamp');
      expect(searchB, isEmpty);
    });
  });
}
