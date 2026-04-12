using UnityEngine;
using UnityEngine.InputSystem;
using System.Collections;

public class HubPlayerScript : MonoBehaviour, PlayerCharacterScript
{
    private bool _finishedBuilding = false;
    public bool finishedBuilding
    {
        get
        {
            return _finishedBuilding;
        }
        set
        {
            _finishedBuilding = value;
        }
    }
    public GameObject hubBuilder;
    public HubBuilderScript hubBuilderScript;
    public GameObject hubTiles;
    public HubTilesScript hubTilesScript;
    public GameObject hubExits;
    public HubExitsScript hubExitsScript;
    public GameObject spriteObject;
    public SpriteRenderer spriteRenderer;
    public GameObject mainHandWeaponSprite;
    public SpriteRenderer mainHandWeaponSpriteRenderer;
    public GameObject offHandWeaponSprite;
    public SpriteRenderer offHandWeaponSpriteRenderer;
    private Sprite[] spriteSheet = new Sprite[2];
    public Sprite[] SpriteSheet
    {
        get
        {
            return spriteSheet;
        }
        set
        {
            spriteSheet = value;
            spriteRenderer.sprite = spriteSheet[0];
        }
    }
    public GameObject gear;
    public GearScript gearScript;

    private Transform _mainHand;
    private Transform _offHand;
    private Transform _neck;
    private Transform _body;
    private Transform _hands;
    private Transform _legs;
    private Transform _feet;
    private Transform _inventory;
    private int _inventorySize;
    private Transform _utilitySkills;
    private int _utilitySkillSlots;
    private int _maxHealth;
    private int _currentHealth;

    public Transform mainHand { get { return _mainHand; } }
    public Transform offHand { get { return _offHand; } }
    public Transform neck { get { return _neck; } }
    public Transform body { get { return _body; } }
    public Transform hands { get { return _hands; } }
    public Transform legs { get { return _legs; } }
    public Transform feet { get { return _feet; } }
    public Transform inventory { get { return _inventory; } }
    public int inventorySize { get { return _inventorySize; } }
    public Transform utilitySkills { get { return _utilitySkills; } }
    public int utilitySkillSlots 
    {
        get
        {
            return _utilitySkillSlots;
        }
        set
        {
            _utilitySkillSlots = value;
        }
    }

    public GameObject mainHandWeapon
    {
        get
        {
            if (mainHand.childCount == 0) return null;
            return mainHand.GetChild(0).gameObject;
        }
    }
    public GameObject offHandWeapon
    {
        get
        {
            if (offHand.childCount == 0) return null;
            return offHand.GetChild(0).gameObject;
        }
    }
    public GameObject amulet
    {
        get
        {
            if (neck.childCount == 0) return null;
            return neck.GetChild(0).gameObject;
        }
    }
    public GameObject gloves
    {
        get
        {
            if (hands.childCount == 0) return null;
            return hands.GetChild(0).gameObject;
        }
    }
    public GameObject pants
    {
        get
        {
            if (legs.childCount == 0) return null;
            return legs.GetChild(0).gameObject;
        }
    }
    public GameObject coat
    {
        get
        {
            if (body.childCount == 0) return null;
            return body.GetChild(0).gameObject;
        }
    }
    public GameObject boots
    {
        get
        {
            if (feet.childCount == 0) return null;
            return feet.GetChild(0).gameObject;
        }
    }
    public GameObject[] inventoryItems
    {
        get
        {
            GameObject[] itemArray = new GameObject[inventorySize];
            for (int i = 0; i < inventory.childCount; i++)
            {
                if (i < inventorySize)
                {
                    itemArray[i] = inventory.GetChild(i).gameObject;
                }
                else
                {
                    Debug.LogError("entity has more items in inventory than inventorySize " + inventorySize.ToString() + " allows");
                }
            }
            return itemArray;
        }
    }
    private GameObject[] _equippedSkillsCache = null;
    public GameObject[] equippedSkills
    {
        get
        {
            if (_equippedSkillsCache == null)
            {
                UpdateEquippedSkills();
            }
            return _equippedSkillsCache;
        }
    }

    public void DisplayWeapons()
    {
        string mainHandType = "none";
        string offHandType = "none";
        if (mainHandWeapon != null)
        {
            WeaponScript mainHandScript = mainHandWeapon.GetComponent<WeaponScript>();
            mainHandType = mainHandScript.ItemSubType();
        }
        if (offHandWeapon != null)
        {
            WeaponScript offHandScript = offHandWeapon.GetComponent<WeaponScript>();
            offHandType = offHandScript.ItemSubType();
        }
        if (mainHandType != "none")
        {
            Sprite[] mainHandSprites = Resources.LoadAll<Sprite>($"Weapons/{mainHandType}");
            mainHandWeaponSpriteRenderer.sprite = mainHandSprites[0];
        }
        if (offHandType != "none")
        {
            Sprite[] offHandSprites = Resources.LoadAll<Sprite>($"Weapons/{offHandType}");
            offHandWeaponSpriteRenderer.sprite = offHandSprites[0];
        }
    }

    public void UpdateEquippedSkills()
    {
        GameObject[] skillArray = new GameObject[8];
        if (mainHandWeapon != null)
        {
            WeaponScript mainHandWeaponScript = mainHandWeapon.GetComponent<WeaponScript>();
            skillArray[0] = mainHandWeaponScript.FirstSkill();
            skillArray[1] = mainHandWeaponScript.SecondSkill();
        }
        if (offHandWeapon != null)
        {
            WeaponScript offHandWeaponScript = offHandWeapon.GetComponent<WeaponScript>();
            skillArray[2] = offHandWeaponScript.ThirdSkill();
        }
        if (utilitySkills.childCount > 0)
        {
            for (int i = 0; i < utilitySkills.childCount; i++)
            {
                if (i < utilitySkillSlots)
                {
                    GameObject utilitySkill = utilitySkills.GetChild(i).gameObject;
                    SkillScript skillScript = utilitySkill.GetComponent<SkillScript>();
                    int skillIndex = skillScript.skillBarPosition - 1;
                    if (skillArray[skillIndex] != null)
                    {
                        Debug.LogError($"there is already a skill in slot {skillIndex}");
                    }
                    else
                    {
                        skillArray[skillIndex] = utilitySkill;
                    }
                }
            }
        }
        _equippedSkillsCache = skillArray;
    }
    public int MaxHealth
    {
        get
        {
            int coatHealth = 0;
            if (coat != null)
            {
                CoatScript coatScript = coat.GetComponent<CoatScript>();
                coatHealth = coatScript.healthBonus;
            }
            int glovesHealth = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesHealth = glovesScript.healthBonus;
            }
            int pantsHealth = 0;
            if (pants != null)
            {
                PantsScript pantsScript = pants.GetComponent<PantsScript>();
                pantsHealth = pantsScript.healthBonus;
            }
            int bootsHealth = 0;
            if (boots != null)
            {
                BootsScript bootsScript = boots.GetComponent<BootsScript>();
                bootsHealth = bootsScript.healthBonus;
            }
            return _maxHealth + coatHealth + glovesHealth + pantsHealth + bootsHealth;
        }
        set
        {
            _maxHealth = value;
        }
    }
    public int CurrentHealth
    {
        get
        {
            return _currentHealth;
        }
        set
        {
            if (value > MaxHealth)
            {
                _currentHealth = MaxHealth;
            }
            else
            {
                _currentHealth = value;
            }
            // Update player health bar if it exists
            if (HubScript.Instance != null)
            {
                GameObject playerHealthBar = HubScript.Instance.playerHealthBar;
                if (playerHealthBar != null)
                {
                    PlayerHealthBarScript playerHealthBarScript = playerHealthBar.GetComponent<PlayerHealthBarScript>();
                    playerHealthBarScript.UpdateHealthBar();
                }
            }
        }
    }
    private int speed = 1;
    public int Speed
    {    
        get
        {
            int bootsSpeed = 0;
            if (boots != null)
            {
                BootsScript bootsScript = boots.GetComponent<BootsScript>();
                bootsSpeed = bootsScript.speedBonus;
            }
            return speed + bootsSpeed;
        }
    }
    private float moveTimer = 0;
    private float baseMoveDelay = 0.3f;
    private float moveDelay
    {
        get
        {
            return baseMoveDelay / (float)Speed;
        }
    }

    public void MoveTo(Vector3 targetPosition, bool isTeleport = false)
    {
        SoundControllerScript.Instance.PlayMoveSound(targetPosition);
        Vector3 currentPosition = this.transform.position;
        float xDif = targetPosition.x - currentPosition.x;
        if (xDif < 0)
        {
            spriteRenderer.sprite = SpriteSheet[0];
        }
        else if (xDif > 0)
        {
            spriteRenderer.sprite = SpriteSheet[0];
        }
        this.transform.position = targetPosition;
        spriteRenderer.sortingOrder = 10 * (int)-targetPosition.y;
        mainHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-targetPosition.y + 1;
        offHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-targetPosition.y + 1;
        CameraControllerScript.Instance.MoveToPlayer();
        // start mission if standing on exit
        if (hubExitsScript.exitLookup.ContainsKey(targetPosition))
        {
            GameObject exit = hubExitsScript.exitLookup[targetPosition];
            ExitScript exitScript = exit.GetComponent<ExitScript>();
            string missionName = exitScript.missionName;
            int missionLength = exitScript.missionLength;
            string endHub = exitScript.endHub;
            PlayerDataScript.Instance.BuildDataFromPlayer(this.gameObject);
#if !UNITY_WEBGL || UNITY_EDITOR
            PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
            GameControllerScript.Instance.StartMission(missionName, missionLength, endHub);
        }
    }

    public int GetSkillCooldown(string skillName)
    {
        return 0;
    }

    public void SetSkillCooldown(string skillName, int number)
    {
    }

    IEnumerator WaitForGear()
    {
        while (!gearScript.finishedBuilding)
        {
            yield return null;
        }
        DisplayWeapons();
        finishedBuilding = true;
    }

    void Awake()
    {
        spriteObject = this.transform.Find("Sprite Object").gameObject;
        spriteRenderer = spriteObject.GetComponent<SpriteRenderer>();
        mainHandWeaponSprite = spriteObject.transform.Find("Main Hand Weapon Sprite").gameObject;
        mainHandWeaponSpriteRenderer = mainHandWeaponSprite.GetComponent<SpriteRenderer>();
        offHandWeaponSprite = spriteObject.transform.Find("Off Hand Weapon Sprite").gameObject;
        offHandWeaponSpriteRenderer = offHandWeaponSprite.GetComponent<SpriteRenderer>();
        SpriteSheet = Resources.LoadAll<Sprite>("Player");
        gear = this.transform.Find("Gear").gameObject;
        gearScript = gear.GetComponent<GearScript>();
        _mainHand = gear.transform.Find("Main Hand");
        _offHand = gear.transform.Find("Off Hand");
        _neck = gear.transform.Find("Neck");
        _body = gear.transform.Find("Body");
        _hands = gear.transform.Find("Hands");
        _legs = gear.transform.Find("Legs");
        _feet = gear.transform.Find("Feet");
        _inventory = this.transform.Find("Inventory");
        _inventorySize = 24 * 4;
        _utilitySkills = this.transform.Find("Utility Skills");
        _maxHealth = 20;
    }

    void Start()
    {
        if (HubScript.Instance != null)
        {
            hubBuilder = HubScript.Instance.hubBuilder;
            hubBuilderScript = HubScript.Instance.hubBuilderScript;
            hubTiles = HubScript.Instance.hubTiles;
            hubTilesScript = HubScript.Instance.hubTilesScript;
            hubExits = HubScript.Instance.hubExits;
            hubExitsScript = HubScript.Instance.hubExitsScript;
        }
        StartCoroutine(WaitForGear());
    }

    void Update()
    {
        moveTimer += Time.deltaTime;
        Keyboard keyboard = Keyboard.current;
        if (keyboard == null) return;

        float horizontalInput = 0;
        float verticalInput = 0;
        if (keyboard.rightArrowKey.isPressed || keyboard.dKey.isPressed)
        {
            horizontalInput = 1;
        }
        if (keyboard.leftArrowKey.isPressed || keyboard.aKey.isPressed)
        {
            horizontalInput = -1;
        }
        if (keyboard.upArrowKey.isPressed || keyboard.wKey.isPressed)
        {
            verticalInput = 1;
        }
        if (keyboard.downArrowKey.isPressed || keyboard.sKey.isPressed)
        {
            verticalInput = -1;
        }
        if (horizontalInput != 0 || verticalInput != 0)
        {
            if (moveTimer >= moveDelay)
            {
                Vector3 moveDelta = new Vector3(horizontalInput, verticalInput, 0);
                Vector3 targetPosition = this.transform.position + moveDelta;
                if (hubTilesScript.tileLookup.ContainsKey(targetPosition))
                {
                    MoveTo(targetPosition);
                    moveTimer = 0;
                }
            }
        }
    }
}
