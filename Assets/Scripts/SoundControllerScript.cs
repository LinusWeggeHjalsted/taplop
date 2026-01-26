using UnityEngine;
using System.Collections;

public class SoundControllerScript : MonoBehaviour
{
    public static SoundControllerScript Instance { get; private set; }
    public AudioSource audioSource;
    public AudioClip buttonClickSound;
    public AudioClip menuSound;
    public AudioClip equipWeaponSound;
    public AudioClip equipArmorSound;
    public AudioClip learnSkillSound;
    public AudioClip salvageSound;
    public AudioClip swapSkillSound;
    public AudioClip moveSound;
    public AudioClip pickupSound;
    public AudioClip attackSound;
    public AudioClip skillSound;
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
    }

    void Start()
    {

    }

    public void PlayButtonClickSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("button click sound");
    }

    public void PlayMenuSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("menu sound");
    }

    public void PlayDefeatSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("defeat sound");
    }

    public void PlayMissionCompletionSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("mission completion sound");
    }

    public void PlayEquipWeaponSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("equip weapon sound");
    }

    public void PlayEquipArmorSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("equip armor sound");
    }

    public void PlayLearnSkillSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("learn skill sound");
    }

    public void PlaySalvageSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("salvage sound");
    }

    public void PlaySwapSkillSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("swap skill sound");
    }

    public void PlayMoveSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("move sound");
    }

    public void PlayPickupSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("pickup sound");
    }

    public void PlayDamageSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("damage sound");
    }

    public void PlayAttackSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("attack sound");
    }

    public void PlaySpellSound(Vector3? position = null)
    {
        Vector3 pos = position ?? Camera.main.transform.position;
        Debug.Log("spell sound");
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
