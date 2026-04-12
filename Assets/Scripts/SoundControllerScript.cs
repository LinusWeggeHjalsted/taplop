using UnityEngine;
using System.Collections;

public class SoundControllerScript : MonoBehaviour
{
    public static SoundControllerScript Instance { get; private set; }
    public AudioSource audioSource;
    public AudioClip ambient;
    public AudioClip buttonClickDownSound;
    public AudioClip buttonClickUpSound;
    public AudioClip menuSound;
    public AudioClip skipSound;
    public AudioClip defeatSound;
    public AudioClip missionCompletionSound;
    public AudioClip equipWeaponSound;
    public AudioClip equipArmorSound;
    public AudioClip learnSkillSound;
    public AudioClip salvageSound;
    public AudioClip swapSkillSound;
    public AudioClip moveSound;
    public AudioClip pickupSound;
    public AudioClip damageSound;
    public AudioClip attackSound;
    public AudioClip spellSound;
    public AudioClip reflectSound;
    public AudioClip stunnedSound;

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
        }
        else
        {
            Destroy(this.gameObject);
        }
        audioSource = this.GetComponent<AudioSource>();
        ambient = Resources.Load<AudioClip>("Music/Ambient");
        buttonClickDownSound = Resources.Load<AudioClip>("Sounds/ButtonClickDown");
        buttonClickUpSound = Resources.Load<AudioClip>("Sounds/ButtonClickUp");
        menuSound = Resources.Load<AudioClip>("Sounds/Menu");
        skipSound = Resources.Load<AudioClip>("Sounds/Skip");
        defeatSound = Resources.Load<AudioClip>("Sounds/Defeat");
        missionCompletionSound = Resources.Load<AudioClip>("Sounds/MissionCompletion");
        equipWeaponSound = Resources.Load<AudioClip>("Sounds/Equip");
        equipArmorSound = Resources.Load<AudioClip>("Sounds/Equip");
        learnSkillSound = Resources.Load<AudioClip>("Sounds/LearnSkill");
        salvageSound = Resources.Load<AudioClip>("Sounds/Salvage");
        swapSkillSound = Resources.Load<AudioClip>("Sounds/SwapSkill");
        moveSound = Resources.Load<AudioClip>("Sounds/Move");
        pickupSound = Resources.Load<AudioClip>("Sounds/Pickup");
        damageSound = Resources.Load<AudioClip>("Sounds/Damage");
        attackSound = Resources.Load<AudioClip>("Sounds/Attack");
        spellSound = Resources.Load<AudioClip>("Sounds/Spell");
    }

    void Start()
    {
        StartCoroutine(PlayAmbientLoop());
    }

    IEnumerator PlayAmbientLoop()
    {
        while (true)
        {
            audioSource.PlayOneShot(ambient);
            yield return new WaitForSeconds(ambient.length);
        }
    }

    public void PlayButtonClickDownSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(buttonClickDownSound);
    }

    public void PlayButtonClickUpSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(buttonClickUpSound);
    }

    public void PlayMenuSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(menuSound);
    }

    public void PlaySkipSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(skipSound);
    }

    public void PlayDefeatSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(defeatSound);
    }

    public void PlayMissionCompletionSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(missionCompletionSound);
    }

    public void PlayEquipWeaponSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(equipWeaponSound);
    }

    public void PlayEquipArmorSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(equipArmorSound);
    }

    public void PlayLearnSkillSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(learnSkillSound);
    }

    public void PlaySalvageSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(salvageSound);
    }

    public void PlaySwapSkillSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(swapSkillSound);
    }

    public void PlayMoveSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        // Match camera z-position for consistent volume in 2D
        pos.z = Camera.main.transform.position.z;
        audioSource.PlayOneShot(moveSound);
    }

    public void PlayPickupSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(pickupSound);
    }

    public void PlayDamageSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        // Match camera z-position for consistent volume in 2D
        pos.z = Camera.main.transform.position.z;
        audioSource.PlayOneShot(damageSound);
    }

    public void PlayAttackSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(attackSound);
    }

    public void PlaySpellSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        audioSource.PlayOneShot(spellSound);
    }

    public void PlayCantripSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("cantrip sound");
    }

    public void PlayEnchantmentSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("enchantment sound");
    }

    public void PlayReflectSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("reflect sound");
    }

    public void PlayStunnedSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("stunned sound");
    }
}
