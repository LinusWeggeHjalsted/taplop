using UnityEngine;
using UnityEngine.UI;
using TMPro;
using System.Collections;
using System.Collections.Generic;

public class PlayerEnchantmentsScript : MonoBehaviour
{
    public static PlayerEnchantmentsScript Instance { get; private set; }
    public GameObject player;
    public EntityScript playerScript;
    public GameObject activeEnchantmentPrefab;

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
        activeEnchantmentPrefab = Resources.Load<GameObject>("Prefabs/UI/Active Enchantment");
    }

    void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    public void UpdateEnchantments()
    {
        // clear displayed enchantments
        for (int i = this.transform.childCount - 1; i >= 0; i--)
        {
            GameObject activeEnchantment = this.transform.GetChild(i).gameObject;
            DestroyImmediate(activeEnchantment);
        }
        // display enchantments
        List<GameObject> playerActiveEnchantments = playerScript.activeEnchantments;
        for (int i = 0; i < playerActiveEnchantments.Count; i++)
        {
            GameObject playerEnchantment = playerActiveEnchantments[i];
            EnchantmentScript playerEnchantmentScript = playerEnchantment.GetComponent<EnchantmentScript>();
            Sprite sprite = playerEnchantmentScript.GetSprite();
            int currentDuration = playerEnchantmentScript.currentDuration;
            GameObject activeEnchantment = Instantiate(activeEnchantmentPrefab, this.transform);
            Image enchantmentImage = activeEnchantment.GetComponent<Image>();
            enchantmentImage.sprite = sprite;
            GameObject durationText = activeEnchantment.transform.GetChild(0).gameObject;
            TMP_Text textField = durationText.GetComponent<TMP_Text>();
            textField.text = currentDuration.ToString();
        }
    }

    void Start()
    {
        player = GameReferences.GetPlayer();
        playerScript = player.GetComponent<EntityScript>();
    }
}
