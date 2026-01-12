using UnityEngine;

public class DefeatScreenScript : MonoBehaviour
{
    void Start()
    {
        SoundControllerScript.Instance.PlayDefeatSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
    }
}
